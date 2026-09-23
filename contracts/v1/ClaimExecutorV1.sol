// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IExecutorV1, SemanticsV1} from "./interfaces/IExecutorV1.sol";
import {IShieldV1} from "./interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "./interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "./interfaces/IDescriptors.sol";
import {ExprLib} from "./libraries/ExprLib.sol";
import {DisposableCloneV1} from "./DisposableCloneV1.sol";

/// @title ClaimExecutorV1
/// @notice The Tier 1 executor for collecting rewards (funding NONE): nothing
///         is pulled from the owner, and every claimed token must reach the
///         owner.
///
/// Claim rules (FLIP-280 F1/F2, 23 Sep). The agent sends no call data. The
/// mandate signs which listed claim rules it uses; at firing the executor
/// builds each claim call itself from the rule, with the owner's address
/// written into the rule's owner arguments, and runs it from a one-use
/// sandbox. So a claim can only ever be the owner's own claim, and nothing is
/// left for the agent to label or relabel. Before anything runs, the core
/// takes the signed claimable read of every reward token (`snapshot`); after
/// the claims each token must have reached the owner by more than the signed
/// dust and by at least that claimable amount less the dust.
///
/// Claim-and-reinvest is not offered in v1 (Austin, 23 Sep): a protocol whose
/// claim pays the owner cannot also pay the sandbox, and reinvesting is a
/// separate mandate on the owner's reward balance.
contract ClaimExecutorV1 is IExecutorV1 {
    string public constant VERSION = "1.0.0";
    bytes32 public constant ACTION_CLAIM_COLLECT = keccak256("claim.collect");
    uint8 public constant CONFIG_VERSION = 1;
    uint256 public constant MAX_CLAIMS = 8;
    uint256 public constant MAX_REWARDS = 8;

    /// @dev Version 1 of the signed configuration, `abi.encode(uint8 version, Config)`.
    struct Config {
        bytes32[] claims; // ids of listed claim rules, run in this order at every firing
        address[] rewardTokens; // the declared reward tokens; nothing else is counted
        ExprLib.Read[] claimable; // one per reward token: what the owner can claim, read before the claims (owner word zero)
        uint256 dust; // per token: a rise at or below this is not a claim; the claimable floor allows this much less
    }

    address public immutable shield;
    /// @dev The listings, catalog, claim rules and emergency controls the core is bound to.
    IShieldRegistryV1 public immutable registry;
    address public immutable cloneTemplate;
    mapping(bytes32 mandateId => uint256) public firings;

    event Claimed(
        bytes32 indexed mandateId, address indexed principal, address indexed token, uint256 amount
    );

    error NotShield();
    error UnsupportedAction(bytes32 action);
    error ConfigInvalid(string field);
    error RouteInvalid(string field);
    error ClaimRuleRevoked(bytes32 id);
    error VenueBlocked(address target);
    error NothingClaimed(address token);
    error BelowClaimable(address token, uint256 received, uint256 claimable);

    modifier onlyShield() {
        if (msg.sender != shield) revert NotShield();
        _;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address shield_) {
        if (shield_.code.length == 0) revert ConfigInvalid("shield");
        shield = shield_;
        registry = IShieldV1(shield_).registry();
        cloneTemplate = address(new DisposableCloneV1(address(this)));
    }

    /// @inheritdoc IExecutorV1
    function semanticsOf(bytes32 action) external pure returns (uint8) {
        if (action == ACTION_CLAIM_COLLECT) return SemanticsV1.CLAIM_COLLECT;
        return SemanticsV1.UNSUPPORTED;
    }

    function nextClone(bytes32 mandateId) external view returns (address) {
        return Clones.predictDeterministicAddress(
            cloneTemplate, _salt(mandateId, firings[mandateId]), address(this)
        );
    }

    /// @inheritdoc IExecutorV1
    function validateConfig(bytes32 action, address, bytes calldata actionConfig) external view {
        if (action != ACTION_CLAIM_COLLECT) revert UnsupportedAction(action);
        Config memory c = _decode(actionConfig);
        uint256 nc = c.claims.length;
        if (nc == 0 || nc > MAX_CLAIMS) revert ConfigInvalid("claims");
        for (uint256 i = 0; i < nc; i++) {
            // forge-lint: disable-next-line(calls-loop,unused-return)
            (, bool listed, bool revoked) = registry.claimRuleOf(c.claims[i]);
            if (!listed || revoked) revert ConfigInvalid("claim:rule");
            for (uint256 j = 0; j < i; j++) {
                if (c.claims[j] == c.claims[i]) revert ConfigInvalid("claim:duplicate");
            }
        }
        uint256 n = c.rewardTokens.length;
        if (n == 0 || n > MAX_REWARDS) revert ConfigInvalid("rewardTokens");
        if (c.claimable.length != n) revert ConfigInvalid("claimable");
        for (uint256 i = 0; i < n; i++) {
            if (!_answersBalanceOf(c.rewardTokens[i])) revert ConfigInvalid("reward:token");
            for (uint256 j = 0; j < i; j++) {
                if (c.rewardTokens[j] == c.rewardTokens[i]) revert ConfigInvalid("reward:duplicate");
            }
            // The claimable read is about the owner and passes the catalog's checks now.
            ExprLib.checkRecipeRead(c.claimable[i], IDescriptors(address(registry)));
        }
    }

    /// @inheritdoc IExecutorV1
    /// @dev What the owner can claim of every reward token, read before anything runs.
    function snapshot(Context calldata ctx, uint256) external view returns (bytes memory) {
        Config memory c = _decode(ctx.actionConfig);
        uint256[] memory claimable = new uint256[](c.rewardTokens.length);
        for (uint256 j = 0; j < claimable.length; j++) {
            int256 v = ExprLib.readAbout(c.claimable[j], ctx.principal, j, IDescriptors(address(registry)));
            // forge-lint: disable-next-line(unsafe-typecast)
            claimable[j] = v > 0 ? uint256(v) : 0;
        }
        return abi.encode(claimable);
    }

    /// @inheritdoc IExecutorV1
    function execute(Context calldata ctx, uint256 amount, bytes calldata route)
        external
        onlyShield
        returns (uint256)
    {
        if (ctx.action != ACTION_CLAIM_COLLECT) revert UnsupportedAction(ctx.action);
        if (amount != 0) revert RouteInvalid("amount");
        // The claims are the signed rules; the agent supplies nothing but the moment.
        if (route.length != 0) revert RouteInvalid("route");
        Config memory c = _decode(ctx.actionConfig);
        uint256[] memory claimable = abi.decode(ctx.before, (uint256[]));
        uint256 n = c.rewardTokens.length;
        if (claimable.length != n) revert RouteInvalid("before");
        uint256[] memory before = new uint256[](n);
        for (uint256 j = 0; j < n; j++) {
            // forge-lint: disable-next-line(calls-loop)
            before[j] = IERC20(c.rewardTokens[j]).balanceOf(ctx.principal);
        }
        address clone =
            Clones.cloneDeterministic(cloneTemplate, _salt(ctx.mandateId, firings[ctx.mandateId]++));
        for (uint256 i = 0; i < c.claims.length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            DisposableCloneV1(clone).step(_claimCall(c.claims[i], ctx.principal));
        }
        // A protocol that pays the caller instead of the owner still pays the
        // owner: the sandbox sweeps every declared token here, and any other
        // token later through its sendToOwner, which pays only the owner.
        DisposableCloneV1(clone).finish(c.rewardTokens, ctx.principal);
        for (uint256 j = 0; j < n; j++) {
            // forge-lint: disable-next-line(calls-loop)
            uint256 got = IERC20(c.rewardTokens[j]).balanceOf(ctx.principal) - before[j];
            if (got <= c.dust) revert NothingClaimed(c.rewardTokens[j]);
            if (got + c.dust < claimable[j]) revert BelowClaimable(c.rewardTokens[j], got, claimable[j]);
            // forge-lint: disable-next-line(reentrancy-events)
            emit Claimed(ctx.mandateId, ctx.principal, c.rewardTokens[j], got);
        }
        return 0;
    }

    /// @dev The one call a listed rule allows, with the owner in every owner argument. A revoked
    ///      rule, or a suspended or revoked venue, stops the firing.
    function _claimCall(bytes32 id, address principal) internal view returns (Call memory k) {
        // forge-lint: disable-next-line(calls-loop,unused-return)
        (IShieldRegistryV1.ClaimRule memory r,, bool revoked) = registry.claimRuleOf(id);
        if (revoked) revert ClaimRuleRevoked(id);
        // forge-lint: disable-next-line(calls-loop)
        if (registry.isVenueBlocked(r.target)) revert VenueBlocked(r.target);
        bytes memory args = r.args;
        for (uint256 i = 0; i < r.argCount; i++) {
            if ((uint256(r.ownerArgs) >> i) & 1 != 0) args = ExprLib.bindAccount(args, i, principal);
        }
        k = Call({
            target: r.target,
            spender: address(0),
            approveToken: address(0),
            approveAmount: 0,
            claimStep: true,
            data: bytes.concat(r.selector, args)
        });
    }

    function _decode(bytes memory actionConfig) internal pure returns (Config memory) {
        (uint8 version, Config memory cfg) = abi.decode(actionConfig, (uint8, Config));
        if (version != CONFIG_VERSION) revert ConfigInvalid("version");
        return cfg;
    }

    function _answersBalanceOf(address token) internal view returns (bool) {
        if (token.code.length == 0) return false;
        // forge-lint: disable-next-line(calls-loop)
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && ret.length >= 32;
    }

    function _salt(bytes32 mandateId, uint256 firing) internal pure returns (bytes32) {
        return keccak256(abi.encode(mandateId, firing));
    }
}

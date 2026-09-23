// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExecutorV1, SemanticsV1} from "./interfaces/IExecutorV1.sol";
import {IShieldV1} from "./interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "./interfaces/IShieldRegistryV1.sol";
import {ExprLib} from "./libraries/ExprLib.sol";
import {DisposableCloneV1} from "./DisposableCloneV1.sol";
import {IPriceOracle} from "contracts/executors/interfaces/IPriceOracle.sol";

/// @title ClaimExecutorV1
/// @notice The Tier 1 executor for no-input actions (funding NONE): collect
///         a claim to the owner, or claim into the sandbox and reinvest.
///         Nothing is pulled from the owner. A claim step carries no
///         approval; the executor measures the declared reward tokens in the
///         sandbox immediately before and after each claim step, so nothing
///         can be pulled back out before it is counted; compose steps may
///         then approve only declared reward tokens to signed venues, and the
///         owner's final position must be worth at least what was claimed at
///         fair value, less the tolerance.
contract ClaimExecutorV1 is IExecutorV1 {
    string public constant VERSION = "1.0.0";
    bytes32 public constant ACTION_CLAIM_COLLECT = keccak256("claim.collect");
    bytes32 public constant ACTION_CLAIM_COMPOSE = keccak256("claim.compose");
    uint8 public constant CONFIG_VERSION = 1;
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint16 public constant MAX_SLIPPAGE_OVERRIDE_BPS = 1_000;
    uint256 public constant MAX_CALLS = 16;
    uint256 public constant MAX_VENUES = 16;
    uint256 public constant MAX_REWARDS = 8;
    uint256 public constant MAX_ROUTE_BYTES = 8192;

    struct Venue {
        address target;
        address spender;
    }

    struct Config {
        Venue[] venues; // claim entry points (spender zero) and, for compose, the reinvest venues
        address[] rewardTokens; // the declared reward tokens; nothing else is counted
        address tokenOut; // COMPOSE: the owner's position that must rise
        address oracle; // COMPOSE: prices for the reward tokens and tokenOut
        uint16 maxSlippageBps;
        bool slippageOverride;
        uint256 dust; // COLLECT: tolerance below which a reward token is considered unpaid, in that token's units
        ExprLib.PriceRound[] prices; // COMPOSE: the signed fresh-round rules for [tokenOut, rewardTokens...]
    }

    address public immutable shield;
    /// @dev The listings, catalog and emergency controls the core is bound to.
    IShieldRegistryV1 public immutable registry;
    address public immutable cloneTemplate;
    mapping(bytes32 mandateId => uint256) public firings;

    event Claimed(
        bytes32 indexed mandateId,
        address indexed principal,
        bytes32 indexed action,
        address clone,
        uint256 valueOut
    );

    error NotShield();
    error UnsupportedAction(bytes32 action);
    error ConfigInvalid(string field);
    error RouteInvalid(string field);
    error VenueNotAllowed(address target, address spender);
    error VenueBlocked(address target);
    error NothingClaimed(address token);
    error OutputBelowMinimum(uint256 received, uint256 minOut);
    error SandboxNotEmpty(address token, uint256 held);

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
        if (action == ACTION_CLAIM_COMPOSE) return SemanticsV1.CLAIM_COMPOSE;
        return SemanticsV1.UNSUPPORTED;
    }

    function nextClone(bytes32 mandateId) external view returns (address) {
        return Clones.predictDeterministicAddress(
            cloneTemplate, _salt(mandateId, firings[mandateId]), address(this)
        );
    }

    /// @inheritdoc IExecutorV1
    function validateConfig(bytes32 action, address, bytes calldata actionConfig) external view {
        Config memory c = _decode(actionConfig);
        if (c.venues.length == 0 || c.venues.length > MAX_VENUES) revert ConfigInvalid("venues");
        if (c.rewardTokens.length == 0 || c.rewardTokens.length > MAX_REWARDS) {
            revert ConfigInvalid("rewardTokens");
        }
        for (uint256 i = 0; i < c.venues.length; i++) {
            if (_isOurs(c.venues[i].target)) revert ConfigInvalid("venue:target");
            if (c.venues[i].spender != address(0) && _isOurs(c.venues[i].spender)) {
                revert ConfigInvalid("venue:spender");
            }
        }
        for (uint256 i = 0; i < c.rewardTokens.length; i++) {
            if (!_answersBalanceOf(c.rewardTokens[i])) revert ConfigInvalid("reward:token");
        }
        uint16 ceiling = c.slippageOverride ? MAX_SLIPPAGE_OVERRIDE_BPS : MAX_SLIPPAGE_BPS;
        if (c.maxSlippageBps > ceiling) revert ConfigInvalid("maxSlippageBps");
        if (action == ACTION_CLAIM_COLLECT) {
            // nothing else needed: the protocol pays the owner, the owner's balances are measured
            if (c.prices.length != 0) revert ConfigInvalid("price:round");
        } else if (action == ACTION_CLAIM_COMPOSE) {
            if (_isOurs(c.tokenOut) || !_answersBalanceOf(c.tokenOut)) revert ConfigInvalid("tokenOut");
            if (c.oracle.code.length == 0 || c.maxSlippageBps == 0) revert ConfigInvalid("oracle");
            if (IPriceOracle(c.oracle).getAssetPrice(c.tokenOut) == 0) revert ConfigInvalid("oracle:out");
            for (uint256 i = 0; i < c.rewardTokens.length; i++) {
                // forge-lint: disable-next-line(calls-loop)
                if (IPriceOracle(c.oracle).getAssetPrice(c.rewardTokens[i]) == 0) {
                    revert ConfigInvalid("oracle:reward");
                }
            }
            address[] memory priced = new address[](c.rewardTokens.length + 1);
            priced[0] = c.tokenOut;
            for (uint256 i = 0; i < c.rewardTokens.length; i++) {
                priced[i + 1] = c.rewardTokens[i];
            }
            if (!ExprLib.priceRoundsMatch(c.prices, priced, registry)) revert ConfigInvalid("price:round");
        } else {
            revert UnsupportedAction(action);
        }
    }

    /// @inheritdoc IExecutorV1
    function snapshot(Context calldata, uint256) external pure returns (bytes memory) {
        return "";
    }

    /// @inheritdoc IExecutorV1
    function execute(Context calldata ctx, uint256 amount, bytes calldata route)
        external
        onlyShield
        returns (uint256)
    {
        if (amount != 0) revert RouteInvalid("amount");
        Config memory c = _decode(ctx.actionConfig);
        Call[] memory calls = _decodeRoute(route);
        if (ctx.action == ACTION_CLAIM_COLLECT) _collect(ctx, c, calls);
        else if (ctx.action == ACTION_CLAIM_COMPOSE) _compose(ctx, c, calls);
        else revert UnsupportedAction(ctx.action);
        return 0;
    }

    /// @dev Every call is a claim step (no approval). The owner's balance of
    ///      every declared reward token must rise by more than the dust.
    function _collect(Context calldata ctx, Config memory c, Call[] memory calls) internal {
        uint256 n = c.rewardTokens.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(calls-loop)
            before[i] = IERC20(c.rewardTokens[i]).balanceOf(ctx.principal);
        }
        address clone = _sandbox(ctx);
        for (uint256 i = 0; i < calls.length; i++) {
            if (!calls[i].claimStep || calls[i].approveAmount != 0 || calls[i].spender != address(0)) {
                revert RouteInvalid("collectStep");
            }
            _checkVenue(c, calls[i]);
            // forge-lint: disable-next-line(calls-loop)
            DisposableCloneV1(clone).step(calls[i]);
        }
        // Whatever a protocol paid the sandbox instead of the owner goes to the owner.
        DisposableCloneV1(clone).finish(c.rewardTokens, ctx.principal);
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(calls-loop)
            uint256 got = IERC20(c.rewardTokens[i]).balanceOf(ctx.principal) - before[i];
            if (got <= c.dust) revert NothingClaimed(c.rewardTokens[i]);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(ctx.mandateId, ctx.principal, ctx.action, clone, 0);
    }

    /// @dev Claim steps pay the sandbox and are measured around each call;
    ///      compose steps may approve declared reward tokens to signed venues.
    ///      At the end the owner's tokenOut position rose by at least the
    ///      claimed value at fair price less the tolerance, and the sandbox
    ///      holds none of the declared tokens.
    function _compose(Context calldata ctx, Config memory c, Call[] memory calls) internal {
        uint256 n = c.rewardTokens.length;
        uint256[] memory claimed = new uint256[](n);
        uint256 outBefore = IERC20(c.tokenOut).balanceOf(ctx.principal);
        address clone = _sandbox(ctx);
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory k = calls[i];
            _checkVenue(c, k);
            if (k.claimStep) {
                if (k.approveAmount != 0 || k.spender != address(0)) revert RouteInvalid("claimApproval");
            } else if (k.approveAmount != 0 && !_isReward(c, k.approveToken)) {
                revert RouteInvalid("approveToken");
            }
            // Every step is measured, whatever the route calls it: any reward
            // that arrives in the sandbox counts as claimed, so a claim the
            // agent labels as something else cannot escape the ledger. A
            // claim step may fall in nothing; a spend step may not raise a
            // declared reward.
            uint256[] memory pre = _sandboxBalances(c, clone);
            // forge-lint: disable-next-line(calls-loop)
            DisposableCloneV1(clone).step(k);
            uint256[] memory post = _sandboxBalances(c, clone);
            for (uint256 j = 0; j < n; j++) {
                if (k.claimStep && post[j] < pre[j]) revert RouteInvalid("claimDrained");
                if (post[j] > pre[j]) claimed[j] += post[j] - pre[j];
            }
        }
        address[] memory sweep = new address[](n + 1);
        for (uint256 j = 0; j < n; j++) {
            sweep[j] = c.rewardTokens[j];
        }
        sweep[n] = c.tokenOut;
        DisposableCloneV1(clone).finish(sweep, ctx.principal);
        for (uint256 j = 0; j < n; j++) {
            // forge-lint: disable-next-line(calls-loop)
            uint256 held = IERC20(c.rewardTokens[j]).balanceOf(clone);
            if (held != 0) revert SandboxNotEmpty(c.rewardTokens[j], held);
        }
        uint256 minOut = _minOut(c, claimed);
        uint256 received = IERC20(c.tokenOut).balanceOf(ctx.principal) - outBefore;
        if (received < minOut) revert OutputBelowMinimum(received, minOut);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(ctx.mandateId, ctx.principal, ctx.action, clone, received);
    }

    // ================================================================== helpers

    function _sandbox(Context calldata ctx) internal returns (address) {
        return Clones.cloneDeterministic(cloneTemplate, _salt(ctx.mandateId, firings[ctx.mandateId]++));
    }

    function _sandboxBalances(Config memory c, address clone) internal view returns (uint256[] memory b) {
        b = new uint256[](c.rewardTokens.length);
        for (uint256 j = 0; j < b.length; j++) {
            // forge-lint: disable-next-line(calls-loop)
            b[j] = IERC20(c.rewardTokens[j]).balanceOf(clone);
        }
    }

    function _checkVenue(Config memory c, Call memory k) internal view {
        bool ok = false;
        for (uint256 i = 0; i < c.venues.length; i++) {
            if (c.venues[i].target == k.target && c.venues[i].spender == k.spender) ok = true;
        }
        if (!ok) revert VenueNotAllowed(k.target, k.spender);
        // forge-lint: disable-next-item(calls-loop)
        if (
            registry.isVenueBlocked(k.target)
                || (k.spender != address(0) && registry.isVenueBlocked(k.spender))
        ) {
            revert VenueBlocked(k.target);
        }
    }

    function _isReward(Config memory c, address token) internal pure returns (bool) {
        for (uint256 j = 0; j < c.rewardTokens.length; j++) {
            if (c.rewardTokens[j] == token) return true;
        }
        return false;
    }

    /// @dev Sum of claimed amounts at fair value, in tokenOut units, less the tolerance.
    function _minOut(Config memory c, uint256[] memory claimed) internal view returns (uint256 minOut) {
        if (registry.isVenueBlocked(c.oracle)) revert VenueBlocked(c.oracle);
        ExprLib.requireFreshPrice(c.prices[0], registry);
        uint256 priceOut = IPriceOracle(c.oracle).getAssetPrice(c.tokenOut);
        if (priceOut == 0) revert ConfigInvalid("oracle:out");
        uint256 decOut = 10 ** IERC20Metadata(c.tokenOut).decimals();
        uint256 fair = 0;
        for (uint256 j = 0; j < claimed.length; j++) {
            if (claimed[j] == 0) continue;
            // A claimed token with no price is not worth zero; it is unpriceable, and the firing fails.
            // forge-lint: disable-next-line(calls-loop)
            ExprLib.requireFreshPrice(c.prices[j + 1], registry);
            // forge-lint: disable-next-line(calls-loop)
            uint256 p = IPriceOracle(c.oracle).getAssetPrice(c.rewardTokens[j]);
            if (p == 0) revert ConfigInvalid("oracle:reward");
            // forge-lint: disable-next-line(calls-loop)
            uint256 dec = 10 ** IERC20Metadata(c.rewardTokens[j]).decimals();
            fair += Math.mulDiv(claimed[j], p * decOut, priceOut * dec);
        }
        if (fair == 0) revert NothingClaimed(address(0));
        minOut = Math.mulDiv(fair, BPS - c.maxSlippageBps, BPS);
        if (minOut == 0) minOut = 1;
    }

    function _decode(bytes memory actionConfig) internal pure returns (Config memory) {
        (uint8 version, Config memory cfg) = abi.decode(actionConfig, (uint8, Config));
        if (version != CONFIG_VERSION) revert ConfigInvalid("version");
        return cfg;
    }

    function _decodeRoute(bytes calldata route) internal pure returns (Call[] memory calls) {
        if (route.length > MAX_ROUTE_BYTES) revert RouteInvalid("size");
        calls = abi.decode(route, (Call[]));
        if (calls.length == 0 || calls.length > MAX_CALLS) revert RouteInvalid("calls");
    }

    function _answersBalanceOf(address token) internal view returns (bool) {
        if (token.code.length == 0) return false;
        // forge-lint: disable-next-line(calls-loop)
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && ret.length >= 32;
    }

    function _isOurs(address candidate) internal view returns (bool) {
        return candidate.code.length == 0 || candidate == shield || candidate == address(this)
            || candidate == cloneTemplate;
    }

    function _salt(bytes32 mandateId, uint256 firing) internal pure returns (bytes32) {
        return keccak256(abi.encode(mandateId, firing));
    }
}

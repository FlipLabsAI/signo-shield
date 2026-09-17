// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";
import {DisposableClone} from "./DisposableClone.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title GenericExecutor
/// @notice Tier 1 bounded execution (FLIP-217 / FLIP-238): one adapter that
///         knows no protocol. The mandate pins the input token (the asset),
///         the output token, one execution surface (a target and the spender
///         it pulls through), and the rule the minimum output is computed
///         from. The agent supplies an amount and calldata, nothing else, and
///         never its own success criteria.
///
///         Two actions:
///         - `generic.transform`: run the agent's calldata against the pinned
///           target from a fresh disposable clone funded with the amount, then
///           require, measured on the OWNER's balances, that the output rose by
///           at least the minimum. What the clone did not spend goes back.
///         - `generic.transfer`: send the amount to the pinned recipient.
///
///         What this contract refuses to claim it can bound: anything that
///         creates or moves an obligation or a position (borrow, withdraw,
///         leverage, LP, credit delegation), bridges, multi-call routes, and
///         any output whose rate has no pinned source. Those are adapters or
///         nothing; see docs/TIER1.md.
contract GenericExecutor is IShieldAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant ACTION_TRANSFORM = keccak256("generic.transform");
    bytes32 public constant ACTION_TRANSFER = keccak256("generic.transfer");

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    /// @notice Hard ceiling on the slippage a mandate may pin for an oracle rate.
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;
    /// @notice What a fixed-rate receipt may fall short by: one basis point plus one unit.
    uint256 public constant ROUNDING_TOLERANCE_BPS = 1;
    /// @notice The largest fixed rate the bound can compute for any amount under 2^128 units.
    uint256 public constant MAX_FIXED_RATE = uint256(type(uint128).max) * WAD;

    /// @notice How the minimum output is computed. The agent has no say.
    enum RateKind {
        /// minOut = amount * rate / 1e18, less rounding tolerance (wraps, 1:1
        /// receipts such as aTokens, which mint a wei short).
        Fixed,
        /// minOut = amount * price(in) / price(out), decimals adjusted, less slippage.
        Oracle,
        /// minOut = the pinned number, whatever the amount (an owner-named floor).
        Floor,
        /// minOut = the vault's own answer to "how many shares for this much
        /// underlying", read BEFORE the agent's call, less the pinned fee
        /// allowance and rounding slack. `tokenOut` is the ERC-4626 vault
        /// itself, and it is also the target and the spender: by the standard
        /// the vault is the receipt token and the deposit surface in one.
        ///
        /// Why a rule and not a Fixed pin: a share is not 1:1 with the
        /// underlying, its price rises as the vault earns, so a rate fixed at
        /// registration would refuse good deposits a month later. Why not the
        /// Oracle rule through a wrapper: two feeds in two bases where one
        /// direct read exists. `convertToShares` MUST round down and MUST NOT
        /// include fees (EIP-4626), so it is a lower bound on the mint for a
        /// fee-less vault; `maxSlippageBps` is the owner's allowance for a
        /// vault that does charge one.
        Erc4626
    }

    /// @notice Pinned at registration for `generic.transform`. The input token
    ///         is the mandate's asset; the recipient is always the principal.
    struct TransformConfig {
        address tokenOut;
        address target;
        address spender;
        RateKind rateKind;
        address oracle;
        uint256 rateOrFloor;
        uint16 maxSlippageBps;
    }

    /// @notice Pinned at registration for `generic.transfer`.
    struct TransferConfig {
        address recipient;
    }

    /// @dev What one transform firing reads before the sandbox runs.
    struct Firing {
        address clone;
        /// Input token already sitting at the predicted sandbox before this
        /// firing funded it. Anyone can put it there; it is swept to the owner
        /// with the rest and must not read as "returned", or a stranger could
        /// brick a mandate for the price of one firing's worth of tokens.
        uint256 parked;
        /// Oracle prices, read before the agent's call runs so a feed the
        /// route could move in the same transaction is not read after it moved.
        uint256 priceIn;
        uint256 priceOut;
        /// ERC-4626: shares per one whole unit of the input, read before the
        /// agent's call for the same reason as the oracle prices.
        uint256 sharesPerUnit;
        uint256 inBefore;
        uint256 outBefore;
    }

    address public immutable shield;
    /// @notice The clone template every firing's sandbox is a proxy of.
    address public immutable cloneTemplate;
    /// @notice Per-mandate firing counter: the salt of the next clone, so a
    ///         caller can know the sandbox address before quoting (aggregators
    ///         pin the wallet that must hold the tokens into their calldata).
    mapping(bytes32 mandateId => uint256) public firings;

    event Transformed(
        bytes32 indexed mandateId,
        address indexed principal,
        address indexed tokenIn,
        address tokenOut,
        address clone,
        uint256 spent,
        uint256 received,
        uint256 minOut
    );
    event Transferred(
        bytes32 indexed mandateId,
        address indexed principal,
        address indexed token,
        address recipient,
        uint256 amount
    );

    error NotShield();
    error UnsupportedAction(bytes32 action);
    error ConfigInvalid(string field);
    error UnexpectedData();
    error NothingSold();
    error OutputBelowMinimum(uint256 received, uint256 minOut);

    modifier onlyShield() {
        if (msg.sender != shield) revert NotShield();
        _;
    }

    // The code-length check refuses the zero address (it has no code).
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address shield_) {
        if (shield_.code.length == 0) revert ConfigInvalid("shield");
        shield = shield_;
        cloneTemplate = address(new DisposableClone(address(this)));
    }

    /// @inheritdoc IShieldAdapter
    function supportsAction(bytes32 action) external pure returns (bool) {
        return action == ACTION_TRANSFORM || action == ACTION_TRANSFER;
    }

    /// @notice The sandbox the next firing of `mandateId` will run in.
    function nextClone(bytes32 mandateId) external view returns (address) {
        return Clones.predictDeterministicAddress(
            cloneTemplate, _salt(mandateId, firings[mandateId]), address(this)
        );
    }

    /// @inheritdoc IShieldAdapter
    function validateConfig(bytes32 action, address asset, bytes calldata actionConfig) external view {
        if (action == ACTION_TRANSFORM) {
            TransformConfig memory c = abi.decode(actionConfig, (TransformConfig));
            if (
                c.tokenOut == asset || c.tokenOut == shield || c.tokenOut == address(this)
                    || c.tokenOut == cloneTemplate || !_answersBalanceOf(c.tokenOut)
            ) {
                revert ConfigInvalid("tokenOut");
            }
            if (!_answersBalanceOf(asset)) revert ConfigInvalid("asset");
            // For a verified 4626 vault the receipt token IS the surface, so
            // `target == tokenOut` is the correct shape rather than the attack
            // `_isReserved` guards against; the vault check runs first so the
            // exception only ever applies to something that proved it is one.
            bool vault = c.rateKind == RateKind.Erc4626;
            if (vault && _vaultAsset(c.tokenOut) != asset) revert ConfigInvalid("vault:asset");
            if (_isReserved(c.target, asset, vault ? address(0) : c.tokenOut)) {
                revert ConfigInvalid("target");
            }
            if (_isReserved(c.spender, asset, vault ? address(0) : c.tokenOut)) {
                revert ConfigInvalid("spender");
            }
            if (c.rateKind == RateKind.Fixed) {
                if (c.rateOrFloor == 0 || c.rateOrFloor > MAX_FIXED_RATE) revert ConfigInvalid("rate");
            } else if (c.rateKind == RateKind.Oracle) {
                if (c.oracle.code.length == 0) revert ConfigInvalid("oracle");
                if (c.maxSlippageBps == 0 || c.maxSlippageBps > MAX_SLIPPAGE_BPS) {
                    revert ConfigInvalid("maxSlippageBps");
                }
                // Dry-run every read the firing will make: a pair the oracle
                // does not price would make a mandate that can never fire.
                if (IPriceOracle(c.oracle).getAssetPrice(asset) == 0) revert ConfigInvalid("oracle:in");
                if (IPriceOracle(c.oracle).getAssetPrice(c.tokenOut) == 0) {
                    revert ConfigInvalid("oracle:out");
                }
                // Both decimals reads must succeed; the values are not the point here.
                // forge-lint: disable-next-line(unused-return)
                IERC20Metadata(asset).decimals();
                // forge-lint: disable-next-line(unused-return)
                IERC20Metadata(c.tokenOut).decimals();
            } else if (c.rateKind == RateKind.Erc4626) {
                // The surface IS the vault. Anything else would put a third
                // party's call between the share-price snapshot and the mint.
                if (c.target != c.tokenOut || c.spender != c.tokenOut) revert ConfigInvalid("vault:surface");
                // No other rate source may be smuggled in beside the vault.
                if (c.oracle != address(0)) revert ConfigInvalid("oracle");
                if (c.rateOrFloor != 0) revert ConfigInvalid("rate");
                if (c.maxSlippageBps > MAX_SLIPPAGE_BPS) revert ConfigInvalid("maxSlippageBps");
                // Dry-run the one read the firing makes.
                if (_sharesPerUnit(c, asset) == 0) revert ConfigInvalid("vault:rate");
            } else {
                if (c.rateOrFloor == 0) revert ConfigInvalid("floor");
            }
        } else if (action == ACTION_TRANSFER) {
            TransferConfig memory c = abi.decode(actionConfig, (TransferConfig));
            if (
                c.recipient == address(0) || c.recipient == asset || c.recipient == shield
                    || c.recipient == address(this) || c.recipient == cloneTemplate
            ) {
                revert ConfigInvalid("recipient");
            }
        } else {
            revert UnsupportedAction(action);
        }
    }

    /// @inheritdoc IShieldAdapter
    function execute(Context calldata ctx, uint256 amount, bytes calldata data)
        external
        onlyShield
        returns (uint256 spent)
    {
        if (ctx.action == ACTION_TRANSFORM) return _transform(ctx, amount, data);
        if (ctx.action == ACTION_TRANSFER) return _transfer(ctx, amount, data);
        revert UnsupportedAction(ctx.action);
    }

    // ---------------------------------------------------------------- actions

    function _transform(Context calldata ctx, uint256 amount, bytes calldata data)
        internal
        returns (uint256 spent)
    {
        TransformConfig memory c = abi.decode(ctx.actionConfig, (TransformConfig));
        Firing memory f;
        f.inBefore = IERC20(ctx.asset).balanceOf(ctx.principal);
        f.outBefore = IERC20(c.tokenOut).balanceOf(ctx.principal);
        if (c.rateKind == RateKind.Oracle) (f.priceIn, f.priceOut) = _prices(c, ctx.asset);
        if (c.rateKind == RateKind.Erc4626) f.sharesPerUnit = _sharesPerUnit(c, ctx.asset);

        // A fresh sandbox, funded with exactly the amount, one call, swept.
        _runSandbox(ctx, c, f, amount, data);

        // Measured on the owner, never reported by the call. What was already
        // parked at the sandbox came back too, but was never this firing's.
        uint256 received = IERC20(c.tokenOut).balanceOf(ctx.principal) - f.outBefore;
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        _settle(ctx, c, f, spent, received);
    }

    /// @dev Deploy the clone for this firing, note what already sat there, fund it, run the one call.
    function _runSandbox(
        Context calldata ctx,
        TransformConfig memory c,
        Firing memory f,
        uint256 amount,
        bytes calldata data
    ) internal {
        f.clone = Clones.cloneDeterministic(cloneTemplate, _salt(ctx.mandateId, firings[ctx.mandateId]++));
        f.parked = IERC20(ctx.asset).balanceOf(f.clone);
        IERC20(ctx.asset).safeTransfer(f.clone, amount);
        DisposableClone(f.clone).run(c.target, c.spender, ctx.asset, amount, data, c.tokenOut, ctx.principal);
    }

    /// @dev The bound, the check, the receipt.
    function _settle(
        Context calldata ctx,
        TransformConfig memory c,
        Firing memory f,
        uint256 spent,
        uint256 received
    ) internal {
        uint256 minOut = _minOut(c, ctx.asset, spent, f);
        // Never zero. Fixed and Oracle rates round down, and for a dust-sized
        // sale the rounding slack can exceed the exact figure, leaving a bound
        // of 0 that `received = 0` satisfies: something sold, nothing back,
        // firing accepted. Bounded to a wei per firing, but "sold for nothing"
        // is not a shape this contract may ever call success.
        if (minOut == 0) minOut = 1;
        if (received < minOut) revert OutputBelowMinimum(received, minOut);
        // After the sandbox ran on purpose: the receipt carries the measured
        // outcome; the Shield is nonReentrant and this contract keeps no state
        // a nested call could reorder.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Transformed(
            ctx.mandateId, ctx.principal, ctx.asset, c.tokenOut, f.clone, spent, received, minOut
        );
    }

    function _transfer(Context calldata ctx, uint256 amount, bytes calldata data) internal returns (uint256) {
        if (data.length != 0) revert UnexpectedData();
        TransferConfig memory c = abi.decode(ctx.actionConfig, (TransferConfig));
        IERC20(ctx.asset).safeTransfer(c.recipient, amount);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Transferred(ctx.mandateId, ctx.principal, ctx.asset, c.recipient, amount);
        return amount;
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The bound, from the pinned rule and what was actually sold. It never
    ///      rounds up; a fixed rate is short by the tolerance, an oracle rate by
    ///      at most one unit of the output token.
    function _minOut(TransformConfig memory c, address tokenIn, uint256 spent, Firing memory f)
        internal
        view
        returns (uint256)
    {
        if (c.rateKind == RateKind.Fixed) {
            return _lessRounding(Math.mulDiv(spent, c.rateOrFloor, WAD));
        }
        if (c.rateKind == RateKind.Floor) return c.rateOrFloor;
        if (c.rateKind == RateKind.Erc4626) {
            // The vault's own lower bound on the mint, scaled to what was sold,
            // less the owner's fee allowance, less rounding slack.
            uint256 exact = Math.mulDiv(spent, f.sharesPerUnit, 10 ** IERC20Metadata(tokenIn).decimals());
            return _lessRounding(Math.mulDiv(exact, BPS - c.maxSlippageBps, BPS));
        }
        // One division: value in, scaled to output units, then the slippage.
        uint256 fair = Math.mulDiv(
            spent,
            f.priceIn * 10 ** IERC20Metadata(c.tokenOut).decimals(),
            f.priceOut * 10 ** IERC20Metadata(tokenIn).decimals()
        );
        return Math.mulDiv(fair, BPS - c.maxSlippageBps, BPS);
    }

    /// @dev One basis point plus one unit of slack, the same for every rule
    ///      that is a lower bound by construction rather than a market price.
    function _lessRounding(uint256 exact) internal pure returns (uint256) {
        uint256 tolerance = Math.mulDiv(exact, ROUNDING_TOLERANCE_BPS, BPS) + 1;
        return exact > tolerance ? exact - tolerance : 0;
    }

    /// @dev Shares the vault would mint for one whole unit of `tokenIn`, read
    ///      before the agent's call. Zero means the vault cannot price it.
    function _sharesPerUnit(TransformConfig memory c, address tokenIn) internal view returns (uint256) {
        return IERC4626(c.tokenOut).convertToShares(10 ** IERC20Metadata(tokenIn).decimals());
    }

    /// @dev The vault's underlying, or the zero address for anything that does
    ///      not answer `asset()` — a plain token, a router, an EOA.
    function _vaultAsset(address vault) internal view returns (address) {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeCall(IERC4626.asset, ()));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev Both oracle prices, read before the agent's call.
    function _prices(TransformConfig memory c, address tokenIn)
        internal
        view
        returns (uint256 priceIn, uint256 priceOut)
    {
        priceIn = IPriceOracle(c.oracle).getAssetPrice(tokenIn);
        priceOut = IPriceOracle(c.oracle).getAssetPrice(c.tokenOut);
        if (priceIn == 0 || priceOut == 0) revert ConfigInvalid("oracle");
    }

    /// @dev True when `token` has code and answers `balanceOf` with a word: the
    ///      one read every firing's measurement depends on.
    function _answersBalanceOf(address token) internal view returns (bool) {
        if (token.code.length == 0) return false;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && ret.length >= 32;
    }

    /// @dev Addresses the surface may never be: the tokens in play, the Shield,
    ///      this contract and its template. A surface that IS the token would
    ///      let the calldata be `approve` or `transfer` on the clone's behalf.
    function _isReserved(address candidate, address tokenIn, address tokenOut) internal view returns (bool) {
        return candidate.code.length == 0 || candidate == tokenIn || candidate == tokenOut
            || candidate == shield || candidate == address(this) || candidate == cloneTemplate;
    }

    function _salt(bytes32 mandateId, uint256 firing) internal pure returns (bytes32) {
        return keccak256(abi.encode(mandateId, firing));
    }
}

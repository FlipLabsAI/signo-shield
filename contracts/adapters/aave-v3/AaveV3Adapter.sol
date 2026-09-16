// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";
import {IAaveOracle, IPool, IPoolAddressesProvider, IPoolDataProvider} from "./interfaces/IAaveV3.sol";

/// @title AaveV3Adapter
/// @notice One adapter for the Aave V3 protocol, one entry point per action.
///         The mandate pins the pair (this adapter, one action), so a repay
///         mandate can never reach the supply path and a bug in one action
///         does not expose every mandate on the protocol.
///
/// Every action follows the same shape: the Shield has already transferred
/// `amount` of the mandate's asset here; the action performs exactly one
/// protocol operation FOR THE PRINCIPAL (`onBehalfOf` is always the
/// principal, never a parameter), checks the outcome on the principal's own
/// balances, returns whatever it did not consume to the principal in the same
/// transaction, clears every approval it granted, and reports what it spent.
/// A failed outcome reverts; nothing here catches a failure and calls it
/// success.
///
/// The adapter holds no state, no funds between transactions, and can be
/// called by nothing but the Shield.
///
/// Actions:
///   - `supply`: asset = the reserve to supply. The principal's aToken balance
///     must rise by the amount (less rounding).
///   - `repay`: asset = the debt asset. The requested amount is clamped to the
///     debt actually owed, the rest goes back; the principal's variable debt
///     must fall by what was repaid. Rate mode is pinned to variable (2): Aave
///     V3 stable borrowing is retired, so it is not an owner field.
///   - `repayWithCollateral`: asset = the aToken of the collateral. The slice
///     of aTokens is withdrawn to the underlying, swapped to the debt asset
///     through the router pinned in the config with the agent's calldata,
///     bounded by a minimum output derived from the Aave oracle and the
///     mandate's slippage limit, then repaid. The principal's health factor
///     must end at or above the pinned target. Aave itself checks the
///     principal's health factor when the aTokens leave their wallet, so a
///     slice that would break the position mid-transaction never gets this far.
contract AaveV3Adapter is IShieldAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant ACTION_SUPPLY = keccak256("aave-v3.supply");
    bytes32 public constant ACTION_REPAY = keccak256("aave-v3.repay");
    bytes32 public constant ACTION_REPAY_WITH_COLLATERAL = keccak256("aave-v3.repayWithCollateral");

    /// @notice Aave V3 variable rate mode. Stable (1) is retired and not offered.
    uint256 public constant VARIABLE_RATE_MODE = 2;
    uint256 public constant BPS = 10_000;
    /// @notice Aave scales aToken and debt balances by a liquidity index, so a
    ///         balance delta can miss the nominal amount by a few wei. One
    ///         basis point plus one wei is the tolerance on outcome checks.
    uint256 public constant ROUNDING_TOLERANCE_BPS = 1;
    /// @notice Ceiling on the slippage a repay-with-collateral mandate may carry.
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;
    /// @notice A target health factor below 1.0 is a liquidation, not a target.
    uint256 public constant MIN_TARGET_HEALTH_FACTOR = 1e18;

    address public immutable shield;
    IPool public immutable pool;
    IPoolAddressesProvider public immutable addressesProvider;

    /// @notice `actionConfig` for `repayWithCollateral`, pinned by the principal.
    /// @param collateral        the reserve whose aToken the mandate pulls
    /// @param debtAsset         the reserve being repaid
    /// @param targetHealthFactor 1e18-scaled; the firing reverts unless the
    ///                           principal ends at or above it
    /// @param maxSlippageBps    haircut on the oracle-fair output the swap must clear
    /// @param router            the only contract the swap calldata may be sent to
    /// @param spender           the contract the collateral is approved to for the
    ///                          swap; aggregators (OKX among them) pull through a
    ///                          separate approval contract, so it is pinned on its own
    struct RepayWithCollateralConfig {
        address collateral;
        address debtAsset;
        uint256 targetHealthFactor;
        uint16 maxSlippageBps;
        address router;
        address spender;
    }

    event Supplied(
        bytes32 indexed mandateId, address indexed principal, address indexed asset, uint256 amount
    );
    event Repaid(
        bytes32 indexed mandateId,
        address indexed principal,
        address indexed asset,
        uint256 repaid,
        uint256 refunded
    );
    event RepaidWithCollateral(
        bytes32 indexed mandateId,
        address indexed principal,
        address indexed collateral,
        uint256 collateralSold,
        address debtAsset,
        uint256 repaid,
        uint256 healthFactor
    );

    error NotShield();
    error UnsupportedAction(bytes32 action);
    error ConfigInvalid(string field);
    error UnexpectedData();
    error NoDebt();
    error OutcomeFailed(string check);
    error SwapFailed(bytes reason);
    error SwapOutputBelowMinimum(uint256 received, uint256 minOut);

    modifier onlyShield() {
        if (msg.sender != shield) revert NotShield();
        _;
    }

    // A code-length check refuses address(0) along with every other non-contract.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address shield_, IPool pool_) {
        if (shield_.code.length == 0) revert ConfigInvalid("shield");
        if (address(pool_).code.length == 0) revert ConfigInvalid("pool");
        shield = shield_;
        pool = pool_;
        addressesProvider = IPoolAddressesProvider(pool_.ADDRESSES_PROVIDER());
    }

    // ------------------------------------------------------------ registration

    /// @inheritdoc IShieldAdapter
    function supportsAction(bytes32 action) public pure returns (bool) {
        return action == ACTION_SUPPLY || action == ACTION_REPAY || action == ACTION_REPAY_WITH_COLLATERAL;
    }

    /// @inheritdoc IShieldAdapter
    function validateConfig(bytes32 action, address asset, bytes calldata actionConfig) external view {
        if (action == ACTION_SUPPLY) {
            if (actionConfig.length != 0) revert ConfigInvalid("actionConfig");
            (address aToken,,) = _reserveTokens(asset);
            if (aToken == address(0)) revert ConfigInvalid("asset");
        } else if (action == ACTION_REPAY) {
            if (actionConfig.length != 0) revert ConfigInvalid("actionConfig");
            (,, address variableDebt) = _reserveTokens(asset);
            if (variableDebt == address(0)) revert ConfigInvalid("asset");
        } else if (action == ACTION_REPAY_WITH_COLLATERAL) {
            RepayWithCollateralConfig memory c = abi.decode(actionConfig, (RepayWithCollateralConfig));
            (address aToken,,) = _reserveTokens(c.collateral);
            // The mandate's asset is the aToken: that is what the Shield pulls.
            if (aToken == address(0) || aToken != asset) revert ConfigInvalid("asset");
            (,, address variableDebt) = _reserveTokens(c.debtAsset);
            if (variableDebt == address(0) || c.debtAsset == c.collateral) revert ConfigInvalid("debtAsset");
            if (c.targetHealthFactor < MIN_TARGET_HEALTH_FACTOR) revert ConfigInvalid("targetHealthFactor");
            if (c.maxSlippageBps == 0 || c.maxSlippageBps > MAX_SLIPPAGE_BPS) {
                revert ConfigInvalid("maxSlippageBps");
            }
            if (c.router.code.length == 0 || c.router == address(pool) || c.router == shield) {
                revert ConfigInvalid("router");
            }
            if (c.spender.code.length == 0 || c.spender == address(pool) || c.spender == shield) {
                revert ConfigInvalid("spender");
            }
        } else {
            revert UnsupportedAction(action);
        }
    }

    // --------------------------------------------------------------- execution

    /// @inheritdoc IShieldAdapter
    function execute(Context calldata ctx, uint256 amount, bytes calldata data)
        external
        onlyShield
        returns (uint256 spent)
    {
        if (ctx.action == ACTION_SUPPLY) return _supply(ctx, amount, data);
        if (ctx.action == ACTION_REPAY) return _repay(ctx, amount, data);
        if (ctx.action == ACTION_REPAY_WITH_COLLATERAL) return _repayWithCollateral(ctx, amount, data);
        revert UnsupportedAction(ctx.action);
    }

    function _supply(Context calldata ctx, uint256 amount, bytes calldata data) internal returns (uint256) {
        if (data.length != 0) revert UnexpectedData();
        IERC20 asset = IERC20(ctx.asset);
        (address aToken,,) = _reserveTokens(ctx.asset);

        uint256 before = IERC20(aToken).balanceOf(ctx.principal);
        asset.forceApprove(address(pool), amount);
        pool.supply(ctx.asset, amount, ctx.principal, 0);
        _clearApproval(asset, address(pool));

        uint256 gained = IERC20(aToken).balanceOf(ctx.principal) - before;
        if (gained + _tolerance(amount) < amount) {
            revert OutcomeFailed("aToken balance did not rise by the amount");
        }

        // Emitted after the protocol call on purpose: it carries the checked outcome.
        // The Shield is nonReentrant and this contract keeps no state to reorder.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Supplied(ctx.mandateId, ctx.principal, ctx.asset, amount);
        return amount;
    }

    function _repay(Context calldata ctx, uint256 amount, bytes calldata data) internal returns (uint256) {
        if (data.length != 0) revert UnexpectedData();
        IERC20 asset = IERC20(ctx.asset);
        (,, address variableDebt) = _reserveTokens(ctx.asset);

        uint256 debtBefore = IERC20(variableDebt).balanceOf(ctx.principal);
        if (debtBefore == 0) revert NoDebt();
        // Never repay more than is owed: the rest goes straight back.
        uint256 want = amount < debtBefore ? amount : debtBefore;

        asset.forceApprove(address(pool), want);
        uint256 repaid = pool.repay(ctx.asset, want, VARIABLE_RATE_MODE, ctx.principal);
        _clearApproval(asset, address(pool));

        uint256 refund = amount - repaid;
        if (refund != 0) asset.safeTransfer(ctx.principal, refund);

        uint256 debtAfter = IERC20(variableDebt).balanceOf(ctx.principal);
        if (debtAfter >= debtBefore) revert OutcomeFailed("debt did not fall");
        if ((debtBefore - debtAfter) + _tolerance(repaid) < repaid) {
            revert OutcomeFailed("debt fell by less than repaid");
        }

        // forge-lint: disable-next-line(reentrancy-events)
        emit Repaid(ctx.mandateId, ctx.principal, ctx.asset, repaid, refund);
        return repaid;
    }

    function _repayWithCollateral(Context calldata ctx, uint256 amount, bytes calldata data)
        internal
        returns (uint256)
    {
        RepayWithCollateralConfig memory c = abi.decode(ctx.actionConfig, (RepayWithCollateralConfig));
        (,, address variableDebt) = _reserveTokens(c.debtAsset);
        uint256 debtBefore = IERC20(variableDebt).balanceOf(ctx.principal);
        if (debtBefore == 0) revert NoDebt();

        (uint256 sold, uint256 received) = _withdrawAndSwap(c, ctx.principal, data);
        uint256 repaid = _repayFromOwnBalance(c.debtAsset, received, debtBefore, ctx.principal);

        // Outcome: the debt fell, and the position is where the owner said it must be.
        if (IERC20(variableDebt).balanceOf(ctx.principal) >= debtBefore) {
            revert OutcomeFailed("debt did not fall");
        }
        // Only the health factor word is needed here; the other five are Aave's aggregates.
        // forge-lint: disable-next-line(unused-return)
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(ctx.principal);
        if (healthFactor < c.targetHealthFactor) revert OutcomeFailed("health factor below target");

        // aToken dust withdraw-all could not take (normally zero) goes back too.
        uint256 aTokenLeft = _returnBalance(IERC20(ctx.asset), ctx.principal);

        // forge-lint: disable-next-item(reentrancy-events)
        emit RepaidWithCollateral(
            ctx.mandateId, ctx.principal, c.collateral, sold, c.debtAsset, repaid, healthFactor
        );
        return amount - aTokenLeft;
    }

    /// @dev Steps 1 and 2 of repay-with-collateral. The slice becomes the
    ///      underlying (withdraw-all takes exactly the aTokens this adapter
    ///      holds, which is what the Shield just sent), then it is swapped
    ///      through the pinned router. The calldata is the agent's; the router,
    ///      the spender, the approval ceiling and the minimum output are not.
    function _withdrawAndSwap(RepayWithCollateralConfig memory c, address principal, bytes calldata data)
        internal
        returns (uint256 sold, uint256 received)
    {
        IERC20 collateral = IERC20(c.collateral);
        IERC20 debtAsset = IERC20(c.debtAsset);

        uint256 withdrawn = pool.withdraw(c.collateral, type(uint256).max, address(this));
        uint256 debtAssetBefore = debtAsset.balanceOf(address(this));

        collateral.forceApprove(c.spender, withdrawn);
        (bool ok, bytes memory reason) = c.router.call(data);
        if (!ok) revert SwapFailed(reason);
        _clearApproval(collateral, c.spender);

        // Unsold collateral goes back to the owner's wallet as the underlying;
        // it is not a loss, so the slippage bound is measured on what was sold.
        // Selling too little to matter is caught by the health-factor target.
        sold = withdrawn - _returnBalance(collateral, principal);
        received = debtAsset.balanceOf(address(this)) - debtAssetBefore;
        uint256 minOut = _minOut(c, sold);
        if (received < minOut) revert SwapOutputBelowMinimum(received, minOut);
    }

    /// @dev Step 3: repay from what the swap delivered, clamped to what is owed.
    ///      Whatever is left of the debt asset goes back to the principal.
    function _repayFromOwnBalance(address debtAsset, uint256 available, uint256 debt, address principal)
        internal
        returns (uint256 repaid)
    {
        IERC20 token = IERC20(debtAsset);
        uint256 want = available < debt ? available : debt;
        token.forceApprove(address(pool), want);
        repaid = pool.repay(debtAsset, want, VARIABLE_RATE_MODE, principal);
        _clearApproval(token, address(pool));
        _returnBalance(token, principal);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Oracle-fair value of `collateralAmount` in debt-asset units, less the
    ///      mandate's slippage haircut. Both prices come from the same Aave
    ///      oracle in the same base currency, so the base cancels.
    function _minOut(RepayWithCollateralConfig memory c, uint256 collateralAmount)
        internal
        view
        returns (uint256)
    {
        IAaveOracle oracle = IAaveOracle(addressesProvider.getPriceOracle());
        uint256 collateralPrice = oracle.getAssetPrice(c.collateral);
        uint256 debtPrice = oracle.getAssetPrice(c.debtAsset);
        if (collateralPrice == 0 || debtPrice == 0) revert OutcomeFailed("oracle price");
        uint256 collateralUnit = 10 ** IERC20Metadata(c.collateral).decimals();
        uint256 debtUnit = 10 ** IERC20Metadata(c.debtAsset).decimals();
        // One division at the end so the haircut does not compound rounding.
        return (collateralAmount * collateralPrice * debtUnit * (BPS - c.maxSlippageBps))
            / (debtPrice * collateralUnit * BPS);
    }

    function _reserveTokens(address asset)
        internal
        view
        returns (address aToken, address stableDebt, address variableDebt)
    {
        return IPoolDataProvider(addressesProvider.getPoolDataProvider()).getReserveTokensAddresses(asset);
    }

    /// @dev Send everything this adapter holds of `token` to `to`. Returns what was sent.
    function _returnBalance(IERC20 token, address to) internal returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(to, amount);
    }

    function _tolerance(uint256 amount) internal pure returns (uint256) {
        return (amount * ROUNDING_TOLERANCE_BPS) / BPS + 1;
    }

    /// @dev No standing authority survives a firing.
    function _clearApproval(IERC20 token, address spender) internal {
        if (token.allowance(address(this), spender) != 0) token.forceApprove(spender, 0);
    }
}

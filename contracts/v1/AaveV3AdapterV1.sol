// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExecutorV1, SemanticsV1} from "./interfaces/IExecutorV1.sol";
import {IShieldV1} from "./interfaces/IShieldV1.sol";
import {
    IAaveOracle,
    IPool,
    IPoolAddressesProvider,
    IPoolDataProvider
} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";

/// @title AaveV3AdapterV1
/// @notice The Tier 2 Aave adapter on the v1 executor interface. Knows one
///         protocol and checks its promise itself: a supply raised the owner's
///         aToken balance by the amount; a repay lowered the debt by what was
///         repaid; a repay with collateral lowered the debt and left the
///         health factor at or above the signed target, with unsold collateral
///         back in the position. The swap leg of the last one takes its route
///         from the agent, against the signed router and spender, both checked
///         against the core's suspension and revocation lists.
contract AaveV3AdapterV1 is IExecutorV1 {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";
    bytes32 public constant ACTION_SUPPLY = keccak256("aave-v3.supply");
    bytes32 public constant ACTION_REPAY = keccak256("aave-v3.repay");
    bytes32 public constant ACTION_REPAY_WITH_COLLATERAL = keccak256("aave-v3.repayWithCollateral");
    uint8 public constant CONFIG_VERSION = 1;
    uint256 public constant VARIABLE_RATE_MODE = 2;
    uint256 public constant BPS = 10_000;
    uint256 public constant ROUNDING_TOLERANCE_BPS = 1;
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint16 public constant MAX_SLIPPAGE_OVERRIDE_BPS = 1_000;
    uint256 public constant MIN_TARGET_HEALTH_FACTOR = 1e18;

    address public immutable shield;
    IPool public immutable pool;
    IPoolAddressesProvider public immutable addressesProvider;

    /// @dev Version 1 of the signed configuration for repay-with-collateral, `abi.encode(uint8 version, Config)`.
    struct RepayWithCollateralConfig {
        address collateral;
        address debtAsset;
        uint256 targetHealthFactor;
        uint16 maxSlippageBps;
        bool slippageOverride;
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
    error VenueBlocked(address target);

    modifier onlyShield() {
        if (msg.sender != shield) revert NotShield();
        _;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address shield_, IPool pool_) {
        if (shield_.code.length == 0) revert ConfigInvalid("shield");
        if (address(pool_).code.length == 0) revert ConfigInvalid("pool");
        shield = shield_;
        pool = pool_;
        addressesProvider = IPoolAddressesProvider(pool_.ADDRESSES_PROVIDER());
    }

    // ============================================================ registration

    /// @inheritdoc IExecutorV1
    function semanticsOf(bytes32 action) external pure returns (uint8) {
        if (action == ACTION_SUPPLY) return SemanticsV1.TRANSFORM;
        if (action == ACTION_REPAY || action == ACTION_REPAY_WITH_COLLATERAL) return SemanticsV1.REPAY;
        return SemanticsV1.UNSUPPORTED;
    }

    /// @inheritdoc IExecutorV1
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
            RepayWithCollateralConfig memory c = _decode(actionConfig);
            (address aToken,,) = _reserveTokens(c.collateral);
            if (aToken == address(0) || aToken != asset) revert ConfigInvalid("asset");
            (,, address variableDebt) = _reserveTokens(c.debtAsset);
            if (variableDebt == address(0) || c.debtAsset == c.collateral) revert ConfigInvalid("debtAsset");
            if (c.targetHealthFactor < MIN_TARGET_HEALTH_FACTOR) revert ConfigInvalid("targetHealthFactor");
            uint16 ceiling = c.slippageOverride ? MAX_SLIPPAGE_OVERRIDE_BPS : MAX_SLIPPAGE_BPS;
            if (c.maxSlippageBps == 0 || c.maxSlippageBps > ceiling) revert ConfigInvalid("maxSlippageBps");
            if (c.router.code.length == 0 || _isReserved(c.router, c, asset, variableDebt)) {
                revert ConfigInvalid("router");
            }
            if (c.spender.code.length == 0 || _isReserved(c.spender, c, asset, variableDebt)) {
                revert ConfigInvalid("spender");
            }
        } else {
            revert UnsupportedAction(action);
        }
    }

    // =============================================================== execution

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
        if (ctx.funding != uint8(IShieldV1.FundingMode.PULL)) revert ConfigInvalid("funding");
        // The pool is the venue of every action here: suspended or revoked, nothing runs.
        if (IShieldV1(shield).isVenueBlocked(address(pool))) revert VenueBlocked(address(pool));
        if (ctx.action == ACTION_SUPPLY) return _supply(ctx, amount, route);
        if (ctx.action == ACTION_REPAY) return _repay(ctx, amount, route);
        if (ctx.action == ACTION_REPAY_WITH_COLLATERAL) return _repayWithCollateral(ctx, amount, route);
        revert UnsupportedAction(ctx.action);
    }

    function _supply(Context calldata ctx, uint256 amount, bytes calldata route) internal returns (uint256) {
        if (route.length != 0) revert UnexpectedData();
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
        // forge-lint: disable-next-line(reentrancy-events)
        emit Supplied(ctx.mandateId, ctx.principal, ctx.asset, amount);
        return amount;
    }

    function _repay(Context calldata ctx, uint256 amount, bytes calldata route) internal returns (uint256) {
        if (route.length != 0) revert UnexpectedData();
        IERC20 asset = IERC20(ctx.asset);
        (,, address variableDebt) = _reserveTokens(ctx.asset);
        uint256 debtBefore = IERC20(variableDebt).balanceOf(ctx.principal);
        if (debtBefore == 0) revert NoDebt();
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

    function _repayWithCollateral(Context calldata ctx, uint256 amount, bytes calldata route)
        internal
        returns (uint256)
    {
        RepayWithCollateralConfig memory c = _decode(ctx.actionConfig);
        IShieldV1 core = IShieldV1(shield);
        if (core.isVenueBlocked(c.router)) revert VenueBlocked(c.router);
        if (core.isVenueBlocked(c.spender)) revert VenueBlocked(c.spender);
        (,, address variableDebt) = _reserveTokens(c.debtAsset);
        uint256 debtBefore = IERC20(variableDebt).balanceOf(ctx.principal);
        if (debtBefore == 0) revert NoDebt();
        (uint256 sold, uint256 received) = _withdrawAndSwap(c, ctx.principal, route);
        if (received > debtBefore + (debtBefore * c.maxSlippageBps) / BPS) {
            revert OutcomeFailed("sold more collateral than the debt needs");
        }
        uint256 repaid = _repayFromOwnBalance(c.debtAsset, received, debtBefore, ctx.principal);
        if (IERC20(variableDebt).balanceOf(ctx.principal) >= debtBefore) {
            revert OutcomeFailed("debt did not fall");
        }
        // forge-lint: disable-next-line(unused-return)
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(ctx.principal);
        if (healthFactor < c.targetHealthFactor) revert OutcomeFailed("health factor below target");
        uint256 aTokenLeft = _returnBalance(IERC20(ctx.asset), ctx.principal);
        // forge-lint: disable-next-item(reentrancy-events)
        emit RepaidWithCollateral(
            ctx.mandateId, ctx.principal, c.collateral, sold, c.debtAsset, repaid, healthFactor
        );
        return sold + aTokenLeft > amount ? amount : sold;
    }

    function _withdrawAndSwap(RepayWithCollateralConfig memory c, address principal, bytes calldata route)
        internal
        returns (uint256 sold, uint256 received)
    {
        uint256 withdrawn = pool.withdraw(c.collateral, type(uint256).max, address(this));
        (sold, received) = _swap(c, withdrawn, route);
        uint256 minOut = _minOut(c, sold);
        if (received < minOut) revert SwapOutputBelowMinimum(received, minOut);
        if (withdrawn > sold) _resupply(IERC20(c.collateral), withdrawn - sold, principal);
    }

    function _swap(RepayWithCollateralConfig memory c, uint256 approved, bytes calldata route)
        internal
        returns (uint256 sold, uint256 received)
    {
        IERC20 collateral = IERC20(c.collateral);
        IERC20 debtAsset = IERC20(c.debtAsset);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 debtAssetBefore = debtAsset.balanceOf(address(this));
        collateral.forceApprove(c.spender, approved);
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok, bytes memory reason) = c.router.call(route);
        if (!ok) revert SwapFailed(reason);
        _clearApproval(collateral, c.spender);
        uint256 collateralAfter = collateral.balanceOf(address(this));
        sold = collateralAfter < collateralBefore ? collateralBefore - collateralAfter : 0;
        if (sold == 0) revert OutcomeFailed("nothing sold");
        received = debtAsset.balanceOf(address(this)) - debtAssetBefore;
    }

    function _resupply(IERC20 collateral, uint256 amount, address principal) internal {
        collateral.forceApprove(address(pool), amount);
        pool.supply(address(collateral), amount, principal, 0);
        _clearApproval(collateral, address(pool));
    }

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

    // ================================================================= helpers

    function _decode(bytes memory actionConfig) internal pure returns (RepayWithCollateralConfig memory c) {
        (uint8 version, RepayWithCollateralConfig memory cfg) =
            abi.decode(actionConfig, (uint8, RepayWithCollateralConfig));
        if (version != CONFIG_VERSION) revert ConfigInvalid("version");
        return cfg;
    }

    function _isReserved(
        address candidate,
        RepayWithCollateralConfig memory c,
        address aToken,
        address variableDebt
    ) internal view returns (bool) {
        return candidate == address(pool) || candidate == shield || candidate == address(this)
            || candidate == c.collateral || candidate == c.debtAsset || candidate == aToken
            || candidate == variableDebt || candidate == address(addressesProvider)
            || candidate == addressesProvider.getPriceOracle();
    }

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

    function _returnBalance(IERC20 token, address to) internal returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(to, amount);
    }

    function _tolerance(uint256 amount) internal pure returns (uint256) {
        return (amount * ROUNDING_TOLERANCE_BPS) / BPS + 1;
    }

    function _clearApproval(IERC20 token, address spender) internal {
        if (token.allowance(address(this), spender) != 0) token.forceApprove(spender, 0);
    }
}

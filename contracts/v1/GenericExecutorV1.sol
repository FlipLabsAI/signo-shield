// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IExecutorV1, SemanticsV1} from "./interfaces/IExecutorV1.sol";
import {IShieldV1} from "./interfaces/IShieldV1.sol";
import {IDescriptors} from "./interfaces/IDescriptors.sol";
import {ExprLib} from "./libraries/ExprLib.sol";
import {DisposableCloneV1} from "./DisposableCloneV1.sol";
import {IPriceOracle} from "contracts/executors/interfaces/IPriceOracle.sol";

/// @title GenericExecutorV1
/// @notice The Tier 1 executor for funded actions: transform (swap, deposit,
///         stake), transfer, redeem (receipt token to underlying) and repay
///         (debt down on a named market). Knows no protocol. Runs the agent's
///         calls in a fresh sandbox, each against a signed (target, spender)
///         pair and the core's suspension and revocation lists, then measures
///         the owner and applies the mandatory check of the semantics. The
///         owner's outcome tree is judged by the core afterwards, in addition.
contract GenericExecutorV1 is IExecutorV1 {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";
    bytes32 public constant ACTION_TRANSFORM = keccak256("generic.transform");
    bytes32 public constant ACTION_TRANSFER = keccak256("generic.transfer");
    bytes32 public constant ACTION_REDEEM = keccak256("generic.redeem");
    bytes32 public constant ACTION_REPAY = keccak256("generic.repay");
    uint8 public constant CONFIG_VERSION = 1;
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    /// @dev Contract-hard slippage ceiling without a signed override, and the absolute ceiling with one.
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint16 public constant MAX_SLIPPAGE_OVERRIDE_BPS = 1_000;
    uint256 public constant ROUNDING_TOLERANCE_BPS = 1;
    uint256 public constant MAX_FIXED_RATE = uint256(type(uint128).max) * WAD;
    uint256 public constant MAX_CALLS = 16;
    uint256 public constant MAX_VENUES = 16;
    uint256 public constant MAX_SWEEP = 16;
    uint256 public constant MAX_ROUTE_BYTES = 8192;

    enum RateKind {
        Fixed,
        Oracle,
        Floor,
        Erc4626
    }

    struct Venue {
        address target;
        address spender;
    }

    /// @dev Version 1 of the signed configuration, `abi.encode(uint8 version, Config)`.
    struct Config {
        Venue[] venues; // exact pairs the sandbox may use; picked by the owner
        address[] sweepSet; // every token the sandbox sweeps to the owner; the asset and tokenOut are added by the executor
        address tokenOut; // TRANSFORM/REDEEM: the position or token the owner expects; REPAY: the debt token
        address market; // REPAY: the lending market the debt and collateral reads name
        uint8 rateKind; // TRANSFORM: RateKind
        uint256 rateOrFloor;
        address oracle; // TRANSFORM with Oracle rate; REDEEM sanity
        uint16 maxSlippageBps;
        bool slippageOverride;
        address recipient; // TRANSFER only
        bytes32 debtDescriptor; // REPAY: descriptor of the owner's debt read on `market`
        bytes32 collateralDescriptor; // REPAY: descriptor of the owner's collateral read on `market`
        uint256 signedAssetsPerShare; // REDEEM: convertToAssets(1 share unit) at signing
        uint16 sanityBandBps; // REDEEM: allowed deviation of the implied share price from signing
    }

    struct Firing {
        address clone;
        uint256 parked;
        uint256 inBefore;
        uint256 outBefore;
        uint256 priceIn;
        uint256 priceOut;
        uint256 sharesPerUnit;
        int256 debtBefore;
        int256 collBefore;
    }

    address public immutable shield;
    address public immutable cloneTemplate;
    mapping(bytes32 mandateId => uint256) public firings;

    event Executed(
        bytes32 indexed mandateId,
        address indexed principal,
        bytes32 indexed action,
        address clone,
        uint256 spent,
        uint256 received,
        uint256 minOut
    );

    error NotShield();
    error UnsupportedAction(bytes32 action);
    error ConfigInvalid(string field);
    error RouteInvalid(string field);
    error VenueNotAllowed(address target, address spender);
    error VenueBlocked(address target);
    error NothingSold();
    error OutputBelowMinimum(uint256 received, uint256 minOut);
    error DebtNotReduced(int256 before, int256 after_, uint256 minDown);
    error CollateralFell(int256 before, int256 after_);
    error SanityBand(uint256 signedRate, uint256 currentRate);

    modifier onlyShield() {
        if (msg.sender != shield) revert NotShield();
        _;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address shield_) {
        if (shield_.code.length == 0) revert ConfigInvalid("shield");
        shield = shield_;
        cloneTemplate = address(new DisposableCloneV1(address(this)));
    }

    /// @inheritdoc IExecutorV1
    function semanticsOf(bytes32 action) external pure returns (uint8) {
        if (action == ACTION_TRANSFORM) return SemanticsV1.TRANSFORM;
        if (action == ACTION_TRANSFER) return SemanticsV1.TRANSFER;
        if (action == ACTION_REDEEM) return SemanticsV1.REDEEM;
        if (action == ACTION_REPAY) return SemanticsV1.REPAY;
        return SemanticsV1.UNSUPPORTED;
    }

    function nextClone(bytes32 mandateId) external view returns (address) {
        return Clones.predictDeterministicAddress(cloneTemplate, _salt(mandateId, firings[mandateId]), address(this));
    }

    // ================================================================= validate

    /// @inheritdoc IExecutorV1
    function validateConfig(bytes32 action, address asset, bytes calldata actionConfig) external view {
        Config memory c = _decode(actionConfig);
        if (!_answersBalanceOf(asset)) revert ConfigInvalid("asset");
        if (c.venues.length == 0 || c.venues.length > MAX_VENUES) revert ConfigInvalid("venues");
        if (c.sweepSet.length > MAX_SWEEP) revert ConfigInvalid("sweepSet");
        bool surfaceIsToken = action == ACTION_REDEEM || (action == ACTION_TRANSFORM && RateKind(c.rateKind) == RateKind.Erc4626);
        for (uint256 i = 0; i < c.venues.length; i++) {
            address t = c.venues[i].target;
            address sp = c.venues[i].spender;
            if (surfaceIsToken ? _isOurs(t) : _isReserved(t, asset, c.tokenOut)) revert ConfigInvalid("venue:target");
            if (sp != address(0) && (surfaceIsToken ? _isOurs(sp) : _isReserved(sp, asset, c.tokenOut))) {
                revert ConfigInvalid("venue:spender");
            }
        }
        for (uint256 i = 0; i < c.sweepSet.length; i++) {
            if (!_answersBalanceOf(c.sweepSet[i])) revert ConfigInvalid("sweep:token");
        }
        _validateSlippage(c);
        if (action == ACTION_TRANSFORM) {
            _validateTransform(c, asset);
        } else if (action == ACTION_TRANSFER) {
            if (
                c.recipient == address(0) || c.recipient == asset || c.recipient == shield || c.recipient == address(this)
                    || c.recipient == cloneTemplate
            ) revert ConfigInvalid("recipient");
        } else if (action == ACTION_REDEEM) {
            _validateRedeem(c, asset);
        } else if (action == ACTION_REPAY) {
            _validateRepay(c, asset);
        } else {
            revert UnsupportedAction(action);
        }
    }

    function _validateSlippage(Config memory c) internal pure {
        uint16 ceiling = c.slippageOverride ? MAX_SLIPPAGE_OVERRIDE_BPS : MAX_SLIPPAGE_BPS;
        if (c.maxSlippageBps > ceiling) revert ConfigInvalid("maxSlippageBps");
    }

    function _validateTransform(Config memory c, address asset) internal view {
        if (c.tokenOut == asset || _isReserved(c.tokenOut, address(0), address(0)) || !_answersBalanceOf(c.tokenOut)) {
            revert ConfigInvalid("tokenOut");
        }
        RateKind k = RateKind(c.rateKind);
        if (k == RateKind.Fixed) {
            if (c.rateOrFloor == 0 || c.rateOrFloor > MAX_FIXED_RATE) revert ConfigInvalid("rate");
        } else if (k == RateKind.Oracle) {
            if (c.oracle.code.length == 0 || c.maxSlippageBps == 0) revert ConfigInvalid("oracle");
            if (IPriceOracle(c.oracle).getAssetPrice(asset) == 0) revert ConfigInvalid("oracle:in");
            if (IPriceOracle(c.oracle).getAssetPrice(c.tokenOut) == 0) revert ConfigInvalid("oracle:out");
            // forge-lint: disable-next-line(unused-return)
            IERC20Metadata(asset).decimals();
            // forge-lint: disable-next-line(unused-return)
            IERC20Metadata(c.tokenOut).decimals();
        } else if (k == RateKind.Erc4626) {
            // The receipt token is the vault; the only venue pair is (vault, vault).
            if (_vaultAsset(c.tokenOut) != asset) revert ConfigInvalid("vault:asset");
            if (c.venues.length != 1 || c.venues[0].target != c.tokenOut || c.venues[0].spender != c.tokenOut) {
                revert ConfigInvalid("vault:surface");
            }
            if (c.oracle != address(0) || c.rateOrFloor != 0) revert ConfigInvalid("vault:rate");
            if (_sharesPerUnit(c.tokenOut, asset) == 0) revert ConfigInvalid("vault:rate");
        } else {
            if (c.rateOrFloor == 0) revert ConfigInvalid("floor");
        }
    }

    function _validateRedeem(Config memory c, address asset) internal view {
        // asset is the receipt token (an ERC-4626 vault); tokenOut is its underlying
        if (_vaultAsset(asset) != c.tokenOut || !_answersBalanceOf(c.tokenOut)) revert ConfigInvalid("redeem:asset");
        if (c.venues.length != 1 || c.venues[0].target != asset || c.venues[0].spender != address(0)) {
            revert ConfigInvalid("redeem:surface");
        }
        if (c.signedAssetsPerShare == 0 || c.sanityBandBps == 0 || c.sanityBandBps > BPS) revert ConfigInvalid("redeem:sanity");
        _checkSanity(c, asset);
    }

    function _validateRepay(Config memory c, address asset) internal view {
        if (c.market.code.length == 0) revert ConfigInvalid("market");
        if (c.tokenOut != asset) revert ConfigInvalid("repay:asset"); // v1: repay in the debt's own asset
        (IDescriptors.Descriptor memory dd, bool dl, bool dr) = IDescriptors(shield).descriptorOf(c.debtDescriptor);
        (IDescriptors.Descriptor memory cd, bool cl, bool cr) = IDescriptors(shield).descriptorOf(c.collateralDescriptor);
        if (!dl || dr || !cl || cr) revert ConfigInvalid("repay:descriptor");
        if (
            dd.subjectRule != IDescriptors.SubjectRule.PrincipalRequired
                || cd.subjectRule != IDescriptors.SubjectRule.PrincipalRequired
        ) revert ConfigInvalid("repay:subject");
    }

    // ================================================================== execute

    /// @inheritdoc IExecutorV1
    function execute(Context calldata ctx, uint256 amount, bytes calldata route)
        external
        onlyShield
        returns (uint256 spent)
    {
        Config memory c = _decode(ctx.actionConfig);
        if (ctx.action == ACTION_TRANSFER) return _transfer(ctx, c, amount, route);
        Call[] memory calls = _decodeRoute(route);
        if (ctx.action == ACTION_TRANSFORM) return _transform(ctx, c, amount, calls);
        if (ctx.action == ACTION_REDEEM) return _redeem(ctx, c, amount, calls);
        if (ctx.action == ACTION_REPAY) return _repay(ctx, c, amount, calls);
        revert UnsupportedAction(ctx.action);
    }

    function _transform(Context calldata ctx, Config memory c, uint256 amount, Call[] memory calls)
        internal
        returns (uint256 spent)
    {
        Firing memory f;
        f.inBefore = IERC20(ctx.asset).balanceOf(ctx.principal);
        f.outBefore = IERC20(c.tokenOut).balanceOf(ctx.principal);
        if (RateKind(c.rateKind) == RateKind.Oracle) (f.priceIn, f.priceOut) = _prices(c, ctx.asset);
        if (RateKind(c.rateKind) == RateKind.Erc4626) f.sharesPerUnit = _sharesPerUnit(c.tokenOut, ctx.asset);
        _runSandbox(ctx, c, f, amount, calls);
        uint256 received = IERC20(c.tokenOut).balanceOf(ctx.principal) - f.outBefore;
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        uint256 minOut = _minOut(c, ctx.asset, spent, f);
        if (minOut == 0) minOut = 1;
        if (received < minOut) revert OutputBelowMinimum(received, minOut);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Executed(ctx.mandateId, ctx.principal, ctx.action, f.clone, spent, received, minOut);
    }

    function _transfer(Context calldata ctx, Config memory c, uint256 amount, bytes calldata route)
        internal
        returns (uint256)
    {
        if (route.length != 0) revert RouteInvalid("transfer");
        uint256 before = IERC20(ctx.asset).balanceOf(c.recipient);
        IERC20(ctx.asset).safeTransfer(c.recipient, amount);
        // Measured, not inferred from a successful call.
        uint256 got = IERC20(ctx.asset).balanceOf(c.recipient) - before;
        if (got < amount) revert OutputBelowMinimum(got, amount);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Executed(ctx.mandateId, ctx.principal, ctx.action, address(0), amount, got, amount);
        return amount;
    }

    /// @dev The mandate asset is the receipt token; the owner receives the underlying.
    function _redeem(Context calldata ctx, Config memory c, uint256 amount, Call[] memory calls)
        internal
        returns (uint256 spent)
    {
        _checkSanity(c, ctx.asset);
        Firing memory f;
        f.inBefore = IERC20(ctx.asset).balanceOf(ctx.principal);
        f.outBefore = IERC20(c.tokenOut).balanceOf(ctx.principal);
        _runSandbox(ctx, c, f, amount, calls);
        uint256 received = IERC20(c.tokenOut).balanceOf(ctx.principal) - f.outBefore;
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        // The vault's own conversion of what was consumed, less the tolerance (a withdrawal fee counts against it).
        uint256 exact = IERC4626(ctx.asset).convertToAssets(spent);
        uint256 minOut = _lessRounding(Math.mulDiv(exact, BPS - c.maxSlippageBps, BPS));
        if (minOut == 0) minOut = 1;
        if (received < minOut) revert OutputBelowMinimum(received, minOut);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Executed(ctx.mandateId, ctx.principal, ctx.action, f.clone, spent, received, minOut);
    }

    /// @dev Debt on the named market fell by at least what was spent less the
    ///      tolerance (interest accrual between reads is inside it), and the
    ///      owner's collateral there did not fall. Both are catalog reads that
    ///      name the principal.
    function _repay(Context calldata ctx, Config memory c, uint256 amount, Call[] memory calls)
        internal
        returns (uint256 spent)
    {
        Firing memory f;
        f.inBefore = IERC20(ctx.asset).balanceOf(ctx.principal);
        f.debtBefore = _read(c.debtDescriptor, c.market, ctx.principal);
        f.collBefore = _read(c.collateralDescriptor, c.market, ctx.principal);
        _runSandbox(ctx, c, f, amount, calls);
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        int256 debtAfter = _read(c.debtDescriptor, c.market, ctx.principal);
        int256 collAfter = _read(c.collateralDescriptor, c.market, ctx.principal);
        uint256 minDown = Math.mulDiv(spent, BPS - c.maxSlippageBps, BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (f.debtBefore - debtAfter < int256(minDown)) revert DebtNotReduced(f.debtBefore, debtAfter, minDown);
        if (collAfter < f.collBefore) revert CollateralFell(f.collBefore, collAfter);
        // forge-lint: disable-next-line(reentrancy-events)
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Executed(ctx.mandateId, ctx.principal, ctx.action, f.clone, spent, uint256(f.debtBefore - debtAfter), minDown);
    }

    // ================================================================== sandbox

    function _runSandbox(Context calldata ctx, Config memory c, Firing memory f, uint256 amount, Call[] memory calls)
        internal
    {
        f.clone = Clones.cloneDeterministic(cloneTemplate, _salt(ctx.mandateId, firings[ctx.mandateId]++));
        f.parked = IERC20(ctx.asset).balanceOf(f.clone);
        IERC20(ctx.asset).safeTransfer(f.clone, amount);
        DisposableCloneV1 clone = DisposableCloneV1(f.clone);
        IShieldV1 core = IShieldV1(shield);
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory k = calls[i];
            if (k.claimStep) revert RouteInvalid("claimStep");
            if (!_venueAllowed(c, k.target, k.spender)) revert VenueNotAllowed(k.target, k.spender);
            // forge-lint: disable-next-line(calls-loop)
            if (core.isVenueBlocked(k.target) || (k.spender != address(0) && core.isVenueBlocked(k.spender))) {
                revert VenueBlocked(k.target);
            }
            if (k.approveAmount != 0 && !_sweepable(c, ctx.asset, k.approveToken)) revert RouteInvalid("approveToken");
            // forge-lint: disable-next-line(calls-loop)
            clone.step(k);
        }
        clone.finish(_sweepList(c, ctx.asset), ctx.principal);
    }

    function _venueAllowed(Config memory c, address target, address spender) internal pure returns (bool) {
        for (uint256 i = 0; i < c.venues.length; i++) {
            if (c.venues[i].target == target && c.venues[i].spender == spender) return true;
        }
        return false;
    }

    function _sweepable(Config memory c, address asset, address token) internal pure returns (bool) {
        if (token == asset || token == c.tokenOut) return true;
        for (uint256 i = 0; i < c.sweepSet.length; i++) {
            if (c.sweepSet[i] == token) return true;
        }
        return false;
    }

    function _sweepList(Config memory c, address asset) internal pure returns (address[] memory list) {
        list = new address[](c.sweepSet.length + 2);
        list[0] = asset;
        list[1] = c.tokenOut == address(0) ? asset : c.tokenOut;
        for (uint256 i = 0; i < c.sweepSet.length; i++) {
            list[i + 2] = c.sweepSet[i];
        }
    }

    // ================================================================== helpers

    function _decode(bytes memory actionConfig) internal pure returns (Config memory c) {
        (uint8 version, Config memory cfg) = abi.decode(actionConfig, (uint8, Config));
        if (version != CONFIG_VERSION) revert ConfigInvalid("version");
        return cfg;
    }

    function _decodeRoute(bytes calldata route) internal pure returns (Call[] memory calls) {
        if (route.length > MAX_ROUTE_BYTES) revert RouteInvalid("size");
        calls = abi.decode(route, (Call[]));
        if (calls.length == 0 || calls.length > MAX_CALLS) revert RouteInvalid("calls");
    }

    /// @dev A catalog read the recipe names: descriptor, the market as target, the principal as the argument.
    function _read(bytes32 descriptor, address market, address principal) internal view returns (int256) {
        ExprLib.Read memory r = ExprLib.Read({
            descriptor: descriptor,
            target: market,
            args: abi.encode(principal),
            subject: ExprLib.Subject.Principal,
            decimals: 0
        });
        return ExprLib.readValue(r, 0, IDescriptors(shield));
    }

    function _checkSanity(Config memory c, address vault) internal view {
        uint256 current = IERC4626(vault).convertToAssets(10 ** IERC20Metadata(vault).decimals());
        uint256 lo = Math.mulDiv(c.signedAssetsPerShare, BPS - c.sanityBandBps, BPS);
        uint256 hi = Math.mulDiv(c.signedAssetsPerShare, BPS + c.sanityBandBps, BPS);
        if (current < lo || current > hi) revert SanityBand(c.signedAssetsPerShare, current);
    }

    function _minOut(Config memory c, address tokenIn, uint256 spent, Firing memory f) internal view returns (uint256) {
        RateKind k = RateKind(c.rateKind);
        if (k == RateKind.Fixed) return _lessRounding(Math.mulDiv(spent, c.rateOrFloor, WAD));
        if (k == RateKind.Floor) return c.rateOrFloor;
        if (k == RateKind.Erc4626) {
            uint256 exact = Math.mulDiv(spent, f.sharesPerUnit, 10 ** IERC20Metadata(tokenIn).decimals());
            return _lessRounding(Math.mulDiv(exact, BPS - c.maxSlippageBps, BPS));
        }
        uint256 fair = Math.mulDiv(
            spent, f.priceIn * 10 ** IERC20Metadata(c.tokenOut).decimals(), f.priceOut * 10 ** IERC20Metadata(tokenIn).decimals()
        );
        return Math.mulDiv(fair, BPS - c.maxSlippageBps, BPS);
    }

    function _lessRounding(uint256 exact) internal pure returns (uint256) {
        uint256 tolerance = Math.mulDiv(exact, ROUNDING_TOLERANCE_BPS, BPS) + 1;
        return exact > tolerance ? exact - tolerance : 0;
    }

    function _sharesPerUnit(address vault, address tokenIn) internal view returns (uint256) {
        return IERC4626(vault).convertToShares(10 ** IERC20Metadata(tokenIn).decimals());
    }

    function _vaultAsset(address vault) internal view returns (address) {
        if (vault.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeCall(IERC4626.asset, ()));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _prices(Config memory c, address tokenIn) internal view returns (uint256 priceIn, uint256 priceOut) {
        priceIn = IPriceOracle(c.oracle).getAssetPrice(tokenIn);
        priceOut = IPriceOracle(c.oracle).getAssetPrice(c.tokenOut);
        if (priceIn == 0 || priceOut == 0) revert ConfigInvalid("oracle");
    }

    function _answersBalanceOf(address token) internal view returns (bool) {
        if (token.code.length == 0) return false;
        // forge-lint: disable-next-line(calls-loop)
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && ret.length >= 32;
    }

    function _isOurs(address candidate) internal view returns (bool) {
        return candidate.code.length == 0 || candidate == shield || candidate == address(this) || candidate == cloneTemplate;
    }

    function _isReserved(address candidate, address tokenIn, address tokenOut) internal view returns (bool) {
        return candidate.code.length == 0 || candidate == tokenIn || candidate == tokenOut || candidate == shield
            || candidate == address(this) || candidate == cloneTemplate;
    }

    function _salt(bytes32 mandateId, uint256 firing) internal pure returns (bytes32) {
        return keccak256(abi.encode(mandateId, firing));
    }
}

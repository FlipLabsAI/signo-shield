// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IExecutorV1, SemanticsV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {DisposableCloneV1} from "contracts/v1/DisposableCloneV1.sol";
import {IPriceOracle} from "contracts/executors/interfaces/IPriceOracle.sol";

/// @title GenericExecutorV1
/// @notice The Tier 1 executor for funded actions: transform (swap, deposit,
///         stake), transfer, redeem (receipt token to underlying) and repay
///         (debt down on a named market). Knows no protocol. Runs the agent's
///         calls in a fresh sandbox, each against a signed (target, spender)
///         pair and the core's suspension and revocation lists, then measures
///         the owner and applies the mandatory check of the semantics. The
///         owner's outcome tree is judged by the core afterwards, in addition.
contract R13PreFixGeneric is IExecutorV1 {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";
    bytes32 public constant ACTION_TRANSFORM = keccak256("generic.transform");
    bytes32 public constant ACTION_TRANSFER = keccak256("generic.transfer");
    bytes32 public constant ACTION_REDEEM = keccak256("generic.redeem");
    bytes32 public constant ACTION_REPAY = keccak256("generic.repay");
    uint8 public constant CONFIG_VERSION = 1;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @dev Contract-hard slippage ceiling without a signed override, and the absolute ceiling with one.
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint16 public constant MAX_SLIPPAGE_OVERRIDE_BPS = 1_000;
    uint256 public constant ROUNDING_TOLERANCE_BPS = 1;
    /// @dev REDEEM: the signed band must span at least this many units of the
    ///      underlying at the signed sample, so the vault's one-unit rounding
    ///      is at most 1% of the band and cannot hide a move it should refuse.
    uint256 public constant MIN_BAND_UNITS = 100;
    /// @dev ERC-4626 deposit: the exact share quote for what was spent must be at
    ///      least this many raw share units, so the vault's one-unit rounding is at
    ///      most 1% of the minimum and cannot hide a loss the slippage should refuse.
    uint256 public constant MIN_QUOTE_UNITS = 100;
    uint256 public constant MAX_FIXED_RATE = uint256(type(uint128).max) * WAD;
    uint256 public constant MAX_CALLS = 16;
    uint256 public constant MAX_VENUES = 16;
    uint256 public constant MAX_SWEEP = 16;
    /// @dev Further outputs a transform may deliver beside `tokenOut`.
    uint256 internal constant MAX_MORE_OUTS = 4;
    uint256 public constant MAX_ROUTE_BYTES = 8192;
    bytes4 private constant SEL_UNDERLYING = 0xb16a19de; // UNDERLYING_ASSET_ADDRESS()

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

    /// @dev A further token a transform may deliver, and (Floor rule) the
    ///      least of it that settles a whole firing on its own.
    struct Output {
        address token;
        uint256 floor;
    }

    /// @dev Version 1 of the signed configuration, `abi.encode(uint8 version, Config)`.
    struct Config {
        Venue[] venues; // exact pairs the sandbox may use; picked by the owner
        address[] sweepSet; // every token the sandbox sweeps to the owner; the asset and tokenOut are added by the executor
        address tokenOut; // TRANSFORM/REDEEM: the position or token the owner expects; REPAY: the debt token
        address market; // REPAY: the contract the debt read targets (for Aave, the variable debt token)
        address collateralTarget; // REPAY: the contract the collateral read targets (for Aave, the collateral aToken)
        uint8 rateKind; // TRANSFORM: RateKind
        uint256 rateOrFloor;
        address oracle; // TRANSFORM with Oracle rate
        uint16 maxSlippageBps;
        bool slippageOverride;
        address recipient; // TRANSFER only
        bytes32 debtDescriptor; // REPAY: descriptor of the owner's debt read on `market`
        bytes32 collateralDescriptor; // REPAY: descriptor of the owner's collateral read on `market`
        uint256 signedShares; // REDEEM, optional floor: the sample it is judged on (for example the whole position)
        uint256 signedAssets; // REDEEM, optional floor: convertToAssets(signedShares) at signing
        uint16 sanityBandBps; // REDEEM, optional floor: how far the sample's value may fall below signing; 0 = no floor
        ExprLib.PriceRound[] prices; // Oracle TRANSFORM: the signed fresh-round rules for [asset, tokenOut, moreOuts...]
        // TRANSFORM (Oracle or Floor): further tokens the route may deliver
        // instead of or beside tokenOut; the loss bound is judged on the value
        // of all of them together, whichever the route chose (round 12).
        Output[] moreOuts;
    }

    struct Firing {
        address clone;
        uint256 parked;
        uint256 inBefore;
        uint256 outBefore;
        uint256 priceIn;
        uint256 priceOut;
        uint256 sharesQuote;
        int256 debtBefore;
        int256 collBefore;
    }

    address public immutable shield;
    /// @dev The listings, catalog and emergency controls the core is bound to.
    IShieldRegistryV1 public immutable registry;
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
    error BeforeMissing();
    error QuoteTooSmall(uint256 shares);

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
        if (action == ACTION_TRANSFORM) return SemanticsV1.TRANSFORM;
        if (action == ACTION_TRANSFER) return SemanticsV1.TRANSFER;
        if (action == ACTION_REDEEM) return SemanticsV1.REDEEM;
        if (action == ACTION_REPAY) return SemanticsV1.REPAY;
        return SemanticsV1.UNSUPPORTED;
    }

    function nextClone(bytes32 mandateId) external view returns (address) {
        return Clones.predictDeterministicAddress(
            cloneTemplate, _salt(mandateId, firings[mandateId]), address(this)
        );
    }

    // ================================================================= validate

    /// @inheritdoc IExecutorV1
    function validateConfig(bytes32 action, address asset, bytes calldata actionConfig) external view {
        Config memory c = _decode(actionConfig);
        if (!_answersBalanceOf(asset)) revert ConfigInvalid("asset");
        // A transfer calls no venue, so it signs none (a decorative venue would
        // read as a check); every other action names at least one.
        if (action == ACTION_TRANSFER
                ? c.venues.length != 0
                : c.venues.length == 0 || c.venues.length > MAX_VENUES) {
            revert ConfigInvalid("venues");
        }
        if (c.sweepSet.length > MAX_SWEEP) revert ConfigInvalid("sweepSet");
        bool surfaceIsToken = action == ACTION_REDEEM
            || (action == ACTION_TRANSFORM && RateKind(c.rateKind) == RateKind.Erc4626);
        for (uint256 i = 0; i < c.venues.length; i++) {
            address t = c.venues[i].target;
            address sp = c.venues[i].spender;
            if (surfaceIsToken ? _isOurs(t) : _isReserved(t, asset, c.tokenOut) || _isMoreOut(c, t)) {
                revert ConfigInvalid("venue:target");
            }
            if (
                sp != address(0)
                    && (surfaceIsToken
                            ? _isOurs(sp)
                            : _isReserved(sp, asset, c.tokenOut) || _isMoreOut(c, sp))
            ) {
                revert ConfigInvalid("venue:spender");
            }
        }
        for (uint256 i = 0; i < c.sweepSet.length; i++) {
            if (!_answersBalanceOf(c.sweepSet[i])) revert ConfigInvalid("sweep:token");
        }
        _validateSlippage(c);
        _validateMoreOuts(c, asset, action);
        // A price rule is signed exactly where a price is read: never a
        // decorative one the owner could mistake for a check.
        bool priced = action == ACTION_TRANSFORM && RateKind(c.rateKind) == RateKind.Oracle;
        if (!priced && c.prices.length != 0) revert ConfigInvalid("price:round");
        if (action == ACTION_TRANSFORM) {
            _validateTransform(c, asset);
        } else if (action == ACTION_TRANSFER) {
            if (
                c.recipient == address(0) || c.recipient == asset || c.recipient == shield
                    || c.recipient == address(this) || c.recipient == cloneTemplate
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
        if (
            c.tokenOut == asset || _isReserved(c.tokenOut, address(0), address(0))
                || !_answersBalanceOf(c.tokenOut)
        ) {
            revert ConfigInvalid("tokenOut");
        }
        RateKind k = RateKind(c.rateKind);
        if (k == RateKind.Fixed) {
            if (c.rateOrFloor == 0 || c.rateOrFloor > MAX_FIXED_RATE) revert ConfigInvalid("rate");
        } else if (k == RateKind.Oracle) {
            if (c.oracle.code.length == 0 || c.maxSlippageBps == 0) revert ConfigInvalid("oracle");
            if (IPriceOracle(c.oracle).getAssetPrice(asset) == 0) revert ConfigInvalid("oracle:in");
            if (IPriceOracle(c.oracle).getAssetPrice(c.tokenOut) == 0) revert ConfigInvalid("oracle:out");
            if (!ExprLib.priceRoundsMatch(c.prices, _outputs(c, asset), registry)) {
                revert ConfigInvalid("price:round");
            }
            // forge-lint: disable-next-line(unused-return)
            IERC20Metadata(asset).decimals();
            // forge-lint: disable-next-line(unused-return)
            IERC20Metadata(c.tokenOut).decimals();
        } else if (k == RateKind.Erc4626) {
            // The receipt token is the vault; the only venue pair is (vault, vault).
            if (_vaultAsset(c.tokenOut) != asset) revert ConfigInvalid("vault:asset");
            if (c.venues.length != 1 || c.venues[0].target != c.tokenOut || c.venues[0].spender != c.tokenOut)
            {
                revert ConfigInvalid("vault:surface");
            }
            if (c.oracle != address(0) || c.rateOrFloor != 0) revert ConfigInvalid("vault:rate");
            // The vault must answer a share quote. A zero quote for ONE whole
            // token is not refused here: a vault whose share is worth more than
            // a token quotes 0 there yet prices a real deposit exactly, and the
            // firing judges precision on the exact amount (FLIP-280 O1).
            if (!_quotesShares(c.tokenOut, asset)) revert ConfigInvalid("vault:rate");
        } else {
            if (c.rateOrFloor == 0) revert ConfigInvalid("floor");
        }
    }

    /// @dev Each further output (transforms only, Oracle or Floor rule): a
    ///      distinct token that is not the asset, answers balanceOf and
    ///      decimals, and carries exactly what its rule reads (an oracle price,
    ///      or a floor).
    function _validateMoreOuts(Config memory c, address asset, bytes32 action) internal view {
        uint256 m = c.moreOuts.length;
        if (m == 0) return;
        RateKind k = RateKind(c.rateKind);
        bool oracle = k == RateKind.Oracle;
        bool bad = action != ACTION_TRANSFORM || m > MAX_MORE_OUTS || (!oracle && k != RateKind.Floor);
        for (uint256 i = 0; i < m && !bad; i++) {
            Output memory o = c.moreOuts[i];
            // Under the oracle rule Aave's oracle must price it; under floors it carries one.
            // forge-lint: disable-next-item(calls-loop)
            bool unjudged =
                oracle ? o.floor != 0 || IPriceOracle(c.oracle).getAssetPrice(o.token) == 0 : o.floor == 0;
            bad = unjudged || o.token == asset || o.token == c.tokenOut
                || _isReserved(o.token, address(0), address(0)) || !_answersBalanceOf(o.token);
            for (uint256 j = 0; j < i; j++) {
                if (c.moreOuts[j].token == o.token) bad = true;
            }
            // forge-lint: disable-next-line(unused-return,calls-loop)
            if (!bad) IERC20Metadata(o.token).decimals();
        }
        if (bad) revert ConfigInvalid("moreOuts");
    }

    function _validateRedeem(Config memory c, address asset) internal view {
        // asset is the receipt token (an ERC-4626 vault); tokenOut is its underlying
        if (_vaultAsset(asset) != c.tokenOut || !_answersBalanceOf(c.tokenOut)) {
            revert ConfigInvalid("redeem:asset");
        }
        if (c.venues.length != 1 || c.venues[0].target != asset || c.venues[0].spender != address(0)) {
            revert ConfigInvalid("redeem:surface");
        }
        // No oracle is consulted for a redemption, so none may be signed here.
        if (c.oracle != address(0) || c.rateOrFloor != 0) revert ConfigInvalid("redeem:oracle");
        // The floor is optional (Austin, 23 Sep, round 7): a withdrawal at a
        // loss is often the point, and a vault whose share value can be moved
        // inside a transaction is kept out by venue review, not by a floor.
        // Without one, nothing about a sample may be signed.
        if (c.sanityBandBps == 0) {
            if (c.signedShares != 0 || c.signedAssets != 0) revert ConfigInvalid("redeem:sanity");
            return;
        }
        if (c.signedShares == 0 || c.signedAssets == 0 || c.sanityBandBps > BPS) {
            revert ConfigInvalid("redeem:sanity");
        }
        // A sample too small to resolve the floor cannot enforce it: refuse the
        // mandate rather than sign a tolerance the contract cannot check.
        if (Math.mulDiv(c.signedAssets, c.sanityBandBps, BPS) < MIN_BAND_UNITS) {
            revert ConfigInvalid("redeem:precision");
        }
        // At signing the sample must match the vault now, within the band on
        // both sides: a wrong sample is refused before it is signed.
        _checkSanity(c, asset, true);
    }

    function _validateRepay(Config memory c, address asset) internal view {
        if (c.market.code.length == 0 || c.collateralTarget.code.length == 0) revert ConfigInvalid("market");
        if (c.tokenOut != asset) revert ConfigInvalid("repay:asset"); // v1: repay in the debt's own asset
        (IDescriptors.Descriptor memory dd, bool dl, bool dr) =
            IDescriptors(address(registry)).descriptorOf(c.debtDescriptor);
        (IDescriptors.Descriptor memory cd, bool cl, bool cr) =
            IDescriptors(address(registry)).descriptorOf(c.collateralDescriptor);
        if (!dl || dr || !cl || cr) revert ConfigInvalid("repay:descriptor");
        _checkRecipeRead(dd, c.market, "repay:debt");
        _checkRecipeRead(cd, c.collateralTarget, "repay:collateral");
        // The debt is measured in the asset's own units: the debt read is
        // `balanceOf` on a debt token that declares the asset as its
        // underlying (Aave's variable debt token), never a base-currency
        // figure and never a token of another asset with the same decimals.
        if (dd.kind != IDescriptors.DescriptorKind.Shape || dd.selector != IERC20.balanceOf.selector) {
            revert ConfigInvalid("repay:units");
        }
        if (_underlyingOf(c.market) != asset) revert ConfigInvalid("repay:units");
        if (IERC20Metadata(c.market).decimals() != IERC20Metadata(asset).decimals()) {
            revert ConfigInvalid("repay:units");
        }
    }

    /// @dev What a debt token says it stands for (`UNDERLYING_ASSET_ADDRESS()`), or zero.
    function _underlyingOf(address token) internal view returns (address) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(SEL_UNDERLYING));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev A recipe read names the principal as the account, is bound to the
    ///      target it will be made on, and takes exactly that one argument.
    function _checkRecipeRead(IDescriptors.Descriptor memory d, address target, string memory field)
        internal
        pure
    {
        if (d.subjectRule != IDescriptors.SubjectRule.PrincipalRequired) revert ConfigInvalid(field);
        if (d.argCount != 1 || d.subjectArg != 0) revert ConfigInvalid(field);
        // An amount is never "infinite": the flag is for the owner's health-factor
        // conditions only, so a flagged read cannot be a debt or collateral check
        // (FLIP-280 G9-H1, round 10).
        if (d.unboundedTop) revert ConfigInvalid(field);
        if (d.kind == IDescriptors.DescriptorKind.PerAddress && d.target != target) {
            revert ConfigInvalid(field);
        }
    }

    /// @inheritdoc IExecutorV1
    function snapshot(Context calldata ctx, uint256 amount) external view returns (bytes memory) {
        Config memory c = _decode(ctx.actionConfig);
        if (ctx.action == ACTION_REPAY) {
            return abi.encode(
                _read(c.debtDescriptor, c.market, ctx.principal),
                _read(c.collateralDescriptor, c.collateralTarget, ctx.principal)
            );
        }
        if (ctx.action == ACTION_REDEEM) {
            // The vault's conversion of the exact amount, before the
            // redemption: the minimum is priced on what the owner had, at
            // full precision, not on a unit quote scaled up.
            _checkSanity(c, ctx.asset, false);
            return abi.encode(IERC4626(ctx.asset).convertToAssets(amount));
        }
        return "";
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
        // tokenOut, then any further outputs the owner signed (round 12).
        address[] memory outs = _outputs(c, address(0));
        uint256[] memory got = new uint256[](outs.length);
        for (uint256 i = 0; i < outs.length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            got[i] = IERC20(outs[i]).balanceOf(ctx.principal);
        }
        if (RateKind(c.rateKind) == RateKind.Oracle) (f.priceIn, f.priceOut) = _prices(c, ctx.asset);
        // The vault's conversion of the exact amount, before the deposit: the
        // minimum is priced at full precision, never a unit quote scaled up.
        if (RateKind(c.rateKind) == RateKind.Erc4626) {
            f.sharesQuote = IERC4626(c.tokenOut).convertToShares(amount);
        }
        _runSandbox(ctx, c, f, amount, calls);
        for (uint256 i = 0; i < outs.length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            got[i] = IERC20(outs[i]).balanceOf(ctx.principal) - got[i];
        }
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        uint256 minOut;
        if (outs.length == 1) {
            minOut = _minOut(c, ctx.asset, spent, amount, f);
            if (minOut == 0) minOut = 1;
            if (got[0] < minOut) revert OutputBelowMinimum(got[0], minOut);
        } else {
            // What each output got is in the receipt's token transfers.
            minOut = _anyOutput(c, ctx.asset, spent, outs, got);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit Executed(ctx.mandateId, ctx.principal, ctx.action, f.clone, spent, got[0], minOut);
    }

    /// @dev Several outputs (round 12, Austin: a mandate bounds the loss, not
    ///      the route): what arrived, summed over every signed output, meets
    ///      the rule. At the oracle, its value is at least the value sold less
    ///      the slippage (WAD-scaled base currency); with floors, each output
    ///      counts as its share of its own floor, and the shares add up to one
    ///      whole firing. Returns what was needed; reverts when short.
    function _anyOutput(
        Config memory c,
        address asset,
        uint256 spent,
        address[] memory outs,
        uint256[] memory got
    ) internal view returns (uint256 need) {
        bool oracle = RateKind(c.rateKind) == RateKind.Oracle;
        need = oracle ? Math.mulDiv(_value(c.oracle, asset, spent), BPS - c.maxSlippageBps, BPS) : WAD;
        uint256 score = 0;
        for (uint256 i = 0; i < outs.length; i++) {
            score += oracle
                ? _value(c.oracle, outs[i], got[i])
                : Math.mulDiv(got[i], WAD, i == 0 ? c.rateOrFloor : c.moreOuts[i - 1].floor);
        }
        if (need == 0) need = 1;
        if (score < need) revert OutputBelowMinimum(score, need);
    }

    /// @dev `amount` of `token` in the oracle's base currency, scaled by WAD
    ///      (rounds down, toward refusing).
    function _value(address oracle, address token, uint256 amount) internal view returns (uint256) {
        // forge-lint: disable-next-line(calls-loop)
        uint256 p = IPriceOracle(oracle).getAssetPrice(token);
        if (p == 0) revert ConfigInvalid("oracle");
        // forge-lint: disable-next-line(calls-loop)
        return Math.mulDiv(amount, p * WAD, 10 ** IERC20Metadata(token).decimals());
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
        if (ctx.before.length != 32) revert BeforeMissing();
        uint256 quote = abi.decode(ctx.before, (uint256)); // convertToAssets(amount), pre-call
        Firing memory f;
        f.inBefore = IERC20(ctx.asset).balanceOf(ctx.principal);
        f.outBefore = IERC20(c.tokenOut).balanceOf(ctx.principal);
        _runSandbox(ctx, c, f, amount, calls);
        // The band holds after the action too: a vault that reprices inside
        // the call does not get to set its own minimum.
        _checkSanity(c, ctx.asset, false);
        uint256 received = IERC20(c.tokenOut).balanceOf(ctx.principal) - f.outBefore;
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        // What was consumed at the pre-call conversion, less the tolerance (a
        // withdrawal fee counts against it). A partial consumption is the
        // exact quote scaled down, never a unit quote scaled up.
        uint256 exact = spent == amount ? quote : Math.mulDiv(quote, spent, amount);
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
        // Taken by the core before the pull (snapshot), not here after it.
        if (ctx.before.length != 64) revert BeforeMissing();
        (f.debtBefore, f.collBefore) = abi.decode(ctx.before, (int256, int256));
        _runSandbox(ctx, c, f, amount, calls);
        uint256 returned = IERC20(ctx.asset).balanceOf(ctx.principal) - f.inBefore;
        returned = returned > f.parked ? returned - f.parked : 0;
        spent = returned >= amount ? 0 : amount - returned;
        if (spent == 0) revert NothingSold();
        int256 debtAfter = _read(c.debtDescriptor, c.market, ctx.principal);
        int256 collAfter = _read(c.collateralDescriptor, c.collateralTarget, ctx.principal);
        uint256 minDown = Math.mulDiv(spent, BPS - c.maxSlippageBps, BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (minDown > uint256(type(int256).max)) revert ConfigInvalid("repay:amount");
        // forge-lint: disable-next-line(unsafe-typecast)
        if (f.debtBefore - debtAfter < int256(minDown)) {
            revert DebtNotReduced(f.debtBefore, debtAfter, minDown);
        }
        if (collAfter < f.collBefore) revert CollateralFell(f.collBefore, collAfter);
        // forge-lint: disable-next-item(reentrancy-events,unsafe-typecast)
        emit Executed(
            ctx.mandateId,
            ctx.principal,
            ctx.action,
            f.clone,
            spent,
            uint256(f.debtBefore - debtAfter),
            minDown
        );
    }

    // ================================================================== sandbox

    function _runSandbox(
        Context calldata ctx,
        Config memory c,
        Firing memory f,
        uint256 amount,
        Call[] memory calls
    ) internal {
        f.clone = Clones.cloneDeterministic(cloneTemplate, _salt(ctx.mandateId, firings[ctx.mandateId]++));
        f.parked = IERC20(ctx.asset).balanceOf(f.clone);
        IERC20(ctx.asset).safeTransfer(f.clone, amount);
        DisposableCloneV1 clone = DisposableCloneV1(f.clone);
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory k = calls[i];
            if (k.claimStep) revert RouteInvalid("claimStep");
            if (!_venueAllowed(c, k.target, k.spender)) revert VenueNotAllowed(k.target, k.spender);
            // forge-lint: disable-next-item(calls-loop)
            if (
                registry.isVenueBlocked(k.target)
                    || (k.spender != address(0) && registry.isVenueBlocked(k.spender))
            ) {
                revert VenueBlocked(k.target);
            }
            if (k.approveAmount != 0 && !_sweepable(c, ctx.asset, k.approveToken)) {
                revert RouteInvalid("approveToken");
            }
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
        if (token == asset || token == c.tokenOut || _isMoreOut(c, token)) return true;
        for (uint256 i = 0; i < c.sweepSet.length; i++) {
            if (c.sweepSet[i] == token) return true;
        }
        return false;
    }

    function _sweepList(Config memory c, address asset) internal pure returns (address[] memory list) {
        uint256 m = c.moreOuts.length;
        list = new address[](c.sweepSet.length + 2 + m);
        list[0] = asset;
        list[1] = c.tokenOut == address(0) ? asset : c.tokenOut;
        for (uint256 i = 0; i < m; i++) {
            list[i + 2] = c.moreOuts[i].token;
        }
        for (uint256 i = 0; i < c.sweepSet.length; i++) {
            list[i + 2 + m] = c.sweepSet[i];
        }
    }

    /// @dev `first` (when set), tokenOut, then the further outputs: the
    ///      outputs of a firing, or with the asset first the tokens an oracle
    ///      transform prices, in the order its rules are signed.
    function _outputs(Config memory c, address first) internal pure returns (address[] memory list) {
        uint256 k = first == address(0) ? 0 : 1;
        list = new address[](c.moreOuts.length + 1 + k);
        if (k == 1) list[0] = first;
        list[k] = c.tokenOut;
        for (uint256 i = 0; i < c.moreOuts.length; i++) {
            list[i + 1 + k] = c.moreOuts[i].token;
        }
    }

    function _isMoreOut(Config memory c, address token) internal pure returns (bool) {
        for (uint256 i = 0; i < c.moreOuts.length; i++) {
            if (c.moreOuts[i].token == token) return true;
        }
        return false;
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
        return ExprLib.readValue(r, 0, IDescriptors(address(registry)));
    }

    /// @dev The optional floor. At a firing only the lower edge applies: the
    ///      sample, quoted now, is worth at least its signed value less the
    ///      band, so growth never blocks a withdrawal. At signing both edges
    ///      apply, so a sample that does not match the vault is refused. Bounds
    ///      round inward (toward refusing); the sample's size was checked at
    ///      admission (MIN_BAND_UNITS). No band = no floor.
    function _checkSanity(Config memory c, address vault, bool atSigning) internal view {
        if (c.sanityBandBps == 0) return;
        uint256 current = IERC4626(vault).convertToAssets(c.signedShares);
        uint256 lo = Math.mulDiv(c.signedAssets, BPS - c.sanityBandBps, BPS, Math.Rounding.Ceil);
        if (current < lo) revert SanityBand(c.signedAssets, current);
        if (atSigning && current > Math.mulDiv(c.signedAssets, BPS + c.sanityBandBps, BPS)) {
            revert SanityBand(c.signedAssets, current);
        }
    }

    function _minOut(Config memory c, address tokenIn, uint256 spent, uint256 amount, Firing memory f)
        internal
        view
        returns (uint256)
    {
        RateKind k = RateKind(c.rateKind);
        if (k == RateKind.Fixed) return _lessRounding(Math.mulDiv(spent, c.rateOrFloor, WAD));
        if (k == RateKind.Floor) return c.rateOrFloor;
        if (k == RateKind.Erc4626) {
            // What was deposited at the pre-call conversion; a partial one is
            // the exact quote scaled down.
            uint256 exact = spent == amount ? f.sharesQuote : Math.mulDiv(f.sharesQuote, spent, amount);
            if (exact < MIN_QUOTE_UNITS) revert QuoteTooSmall(exact);
            return _lessRounding(Math.mulDiv(exact, BPS - c.maxSlippageBps, BPS));
        }
        uint256 fair = Math.mulDiv(
            spent,
            f.priceIn * 10 ** IERC20Metadata(c.tokenOut).decimals(),
            f.priceOut * 10 ** IERC20Metadata(tokenIn).decimals()
        );
        return Math.mulDiv(fair, BPS - c.maxSlippageBps, BPS);
    }

    function _lessRounding(uint256 exact) internal pure returns (uint256) {
        uint256 tolerance = Math.mulDiv(exact, ROUNDING_TOLERANCE_BPS, BPS) + 1;
        return exact > tolerance ? exact - tolerance : 0;
    }

    /// @dev The vault answers `convertToShares` for one whole input token (any value, zero included).
    function _quotesShares(address vault, address tokenIn) internal view returns (bool) {
        (bool ok, bytes memory ret) = vault.staticcall(
            abi.encodeCall(IERC4626.convertToShares, (10 ** IERC20Metadata(tokenIn).decimals()))
        );
        return ok && ret.length >= 32;
    }

    function _vaultAsset(address vault) internal view returns (address) {
        if (vault.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeCall(IERC4626.asset, ()));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _prices(Config memory c, address tokenIn)
        internal
        view
        returns (uint256 priceIn, uint256 priceOut)
    {
        // The oracle is a dependency like any venue: a suspended or revoked one stops the firing.
        if (registry.isVenueBlocked(c.oracle)) revert VenueBlocked(c.oracle);
        // A positive price, and the fresh underlying round the owner signed (admitted equal to the registry's rule).
        for (uint256 i = 0; i < c.prices.length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            ExprLib.requireFreshPrice(c.prices[i], registry);
        }
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
        return candidate.code.length == 0 || candidate == shield || candidate == address(this)
            || candidate == cloneTemplate;
    }

    function _isReserved(address candidate, address tokenIn, address tokenOut) internal view returns (bool) {
        return candidate.code.length == 0 || candidate == tokenIn || candidate == tokenOut
            || candidate == shield || candidate == address(this) || candidate == cloneTemplate;
    }

    function _salt(bytes32 mandateId, uint256 firing) internal pure returns (bytes32) {
        return keccak256(abi.encode(mandateId, firing));
    }
}

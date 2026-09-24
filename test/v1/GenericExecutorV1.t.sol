// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockFeed} from "test/v1/mocks/MockCatalog.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {DisposableCloneV1} from "contracts/v1/DisposableCloneV1.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {MockFeeToken, MockToken} from "./mocks/MockExecutor.sol";
import {MockDex, MockOracle, MockVault, MockMarket} from "./mocks/MockVenues.sol";

contract GenericExecutorV1Test is Test {
    ShieldV1 internal shield;
    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    GenericExecutorV1 internal exec;
    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal mid; // an intermediate token a route can leave behind
    MockDex internal dex;
    MockOracle internal oracle;
    MockVault internal vault;
    MockMarket internal market;

    address internal admin = address(0xAD);
    address internal enforcer = address(0xE0);
    address internal principal = address(0xA11CE);
    address internal agent = address(0xA6E);
    bytes32 internal dDebt;
    bytes32 internal dColl;
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");
    bytes32 internal constant TRANSFER = keccak256("generic.transfer");
    bytes32 internal constant REDEEM = keccak256("generic.redeem");
    bytes32 internal constant REPAY = keccak256("generic.repay");

    function setUp() public {
        registry = new ShieldRegistryV1(admin);
        shield = new ShieldV1(registry, 0);
        ev = new ExpressionEvaluator(registry);
        exec = new GenericExecutorV1(address(shield));
        usdc = new MockToken();
        weth = new MockToken();
        mid = new MockToken();
        dex = new MockDex();
        oracle = new MockOracle();
        vault = new MockVault(IERC20(address(usdc)));
        market = new MockMarket(IERC20(address(usdc)));
        oracle.set(address(usdc), 1e8);
        oracle.set(address(weth), 1e8); // 1:1 for readable numbers
        vm.startPrank(admin);
        registry.setEnforcer(enforcer, true);
        registry.setExecutor(address(exec), true);
        registry.setEvaluator(address(ev), true);
        dDebt = registry.listDescriptor(_shape(bytes4(keccak256("balanceOf(address)")))); // the debt token's balance
        dColl = registry.listDescriptor(_shape(bytes4(keccak256("collateralOf(address)"))));
        vm.stopPrank();
        usdc.mint(principal, 1_000_000e18);
        vm.prank(principal);
        usdc.approve(address(shield), type(uint256).max);
    }

    function _shape(bytes4 sel) internal pure returns (IDescriptors.Descriptor memory) {
        return IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.Shape,
            target: address(0),
            selector: sel,
            argCount: 1,
            subjectArg: 0,
            subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
            word: 0,
            isSigned: false,
            mustBePositive: false,
            decimals: 0,
            freshness: IDescriptors.Freshness.None,
            maxAge: 0,
            gasStipend: 100_000,
            copyBytes: 32,
            unboundedTop: false
        });
    }

    function _cfg() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(dex), spender: address(dex)});
        c.sweepSet = new address[](1);
        c.sweepSet[0] = address(mid);
        c.tokenOut = address(weth);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Oracle);
        c.oracle = address(oracle);
        c.maxSlippageBps = 50;
    }

    function _params(bytes32 action, address asset, GenericExecutorV1.Config memory c, uint8 funding)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        // An Oracle transform signs the registry's price rules. This suite binds no round, so
        // the rules are the explicit no-round mode. Built without external calls, so a
        // `vm.prank` or `vm.expectRevert` placed before `registerMandate(_params(...))` still
        // reaches the registration.
        ExprLib.PriceRound[] memory given = c.prices;
        if (
            action == TRANSFORM && c.rateKind == uint8(GenericExecutorV1.RateKind.Oracle) && given.length == 0
        ) {
            c.prices = new ExprLib.PriceRound[](2);
            c.prices[0] = ExprLib.PriceRound(asset, bytes32(0), address(0));
            c.prices[1] = ExprLib.PriceRound(c.tokenOut, bytes32(0), address(0));
        }
        p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(exec),
            evaluator: address(ev),
            asset: asset,
            maxTransactionValue: 1_000e18,
            maxCumulativeValue: 10_000e18,
            validFrom: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 0,
            funding: funding,
            action: action,
            actionConfig: abi.encode(uint8(1), c),
            trigger: "",
            outcome: ""
        });
        c.prices = given;
    }

    function _swapCall(uint256 amountIn, address to) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call({
            target: address(dex),
            spender: address(dex),
            approveToken: address(usdc),
            approveAmount: amountIn,
            claimStep: false,
            data: abi.encodeCall(MockDex.swap, (address(usdc), address(weth), amountIn, to))
        });
    }

    function _route(IExecutorV1.Call memory k) internal pure returns (bytes memory) {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = k;
        return abi.encode(calls);
    }

    // ---------------------------------------------------------------- transform

    function test_transformSwapThroughSandboxMeasuredOnOwner() public {
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFORM, address(usdc), _cfg(), 0));
        address clone = exec.nextClone(id);
        uint256 wBefore = weth.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e18, _route(_swapCall(100e18, clone)));
        assertEq(spent, 100e18);
        assertEq(weth.balanceOf(principal) - wBefore, 100e18); // swept from the sandbox to the owner
        assertEq(usdc.balanceOf(clone), 0);
        assertEq(weth.balanceOf(clone), 0);
    }

    function test_transformRejectsBelowMinimumAndRollsBack() public {
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFORM, address(usdc), _cfg(), 0));
        dex.setSkim(100); // 1% short, tolerance is 0.5%
        uint256 uBefore = usdc.balanceOf(principal);
        address clone = exec.nextClone(id);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(_swapCall(100e18, clone)));
        assertEq(usdc.balanceOf(principal), uBefore);
    }

    function test_venueNotInMandateAndBlockedVenueAreRefused() public {
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFORM, address(usdc), _cfg(), 0));
        MockDex other = new MockDex();
        IExecutorV1.Call memory k = _swapCall(100e18, exec.nextClone(id));
        k.target = address(other);
        k.spender = address(other);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(k));
        // the signed venue, suspended by the enforcer, is refused too
        vm.prank(enforcer);
        registry.suspend(address(dex));
        address clone = exec.nextClone(id);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(_swapCall(100e18, clone)));
    }

    function test_approveTokenMustBeAssetOrSweepSetAndOwnerTokensAreOutOfReach() public {
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFORM, address(usdc), _cfg(), 0));
        // approval on a token the mandate never named
        MockToken stranger = new MockToken();
        IExecutorV1.Call memory k = _swapCall(100e18, exec.nextClone(id));
        k.approveToken = address(stranger);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(k));
        // a venue entry that pulls from a named payer finds nothing: the owner never approved the venue
        IExecutorV1.Call memory bad = IExecutorV1.Call({
            target: address(dex),
            spender: address(dex),
            approveToken: address(usdc),
            approveAmount: 0,
            claimStep: false,
            data: abi.encodeCall(MockDex.swapFrom, (principal, address(usdc), 1e18, address(0xBAD)))
        });
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(bad));
    }

    function test_intermediateTokenIsSweptToOwner() public {
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFORM, address(usdc), _cfg(), 0));
        address clone = exec.nextClone(id);
        mid.mint(clone, 7e18); // a route that left an intermediate in the sandbox (modelled before the firing)
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapCall(100e18, clone)));
        assertEq(mid.balanceOf(clone), 0);
        assertEq(mid.balanceOf(principal), 7e18);
    }

    /// Round 7: a token no mandate declared, left in a used sandbox (paid by a venue
    /// after the firing, or never in the sweep set), reaches the owner and no one else.
    function test_undeclaredTokenInUsedSandboxGoesOnlyToOwner() public {
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFORM, address(usdc), _cfg(), 0));
        address clone = exec.nextClone(id);
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapCall(100e18, clone)));
        MockToken stray = new MockToken();
        stray.mint(clone, 5e18);
        address[] memory tokens = new address[](2);
        tokens[0] = address(stray);
        tokens[1] = address(weth); // already empty: skipped, not a failure
        address stranger = address(0xBEEF);
        vm.prank(stranger);
        DisposableCloneV1(clone).sendToOwner(tokens);
        assertEq(stray.balanceOf(principal), 5e18);
        assertEq(stray.balanceOf(clone), 0);
        assertEq(stray.balanceOf(stranger), 0);
    }

    function test_sendToOwnerNeedsAFinishedFiring() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        address template = exec.cloneTemplate();
        usdc.mint(template, 1e18);
        vm.expectRevert(DisposableCloneV1.NotFinished.selector);
        DisposableCloneV1(template).sendToOwner(tokens);
    }

    // ----------------------------------------------------------------- transfer

    function test_transferMeasuresRecipient() public {
        GenericExecutorV1.Config memory c = _cfg();
        c.venues = new GenericExecutorV1.Venue[](0); // a transfer calls no venue
        c.recipient = address(0xBEEF);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(TRANSFER, address(usdc), c, 0));
        vm.prank(agent);
        uint256 spent = shield.fire(id, 25e18, "");
        assertEq(spent, 25e18);
        assertEq(usdc.balanceOf(address(0xBEEF)), 25e18);
    }

    /// Round 8: a transfer signs no venue. Before, it had to sign one (with code) that it
    /// never calls, so a transfer to a wallet could not be registered without a decoy.
    function test_transferRefusesAVenue() public {
        GenericExecutorV1.Config memory c = _cfg();
        c.recipient = address(0xBEEF);
        IShieldV1.MandateParams memory p = _params(TRANSFER, address(usdc), c, 0);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "venues"));
        shield.registerMandate(p);
    }

    // ------------------------------------------------------------------- redeem

    function _vaultShares(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(principal);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, principal);
        vault.approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    function _redeemCfg() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(vault), spender: address(0)});
        c.sweepSet = new address[](0);
        c.tokenOut = address(usdc);
        c.maxSlippageBps = 50;
        c.signedShares = 1_000e18; // the sample: the size of the position these tests redeem
        c.signedAssets = vault.convertToAssets(c.signedShares);
        c.sanityBandBps = 500;
    }

    function test_redeemSharesToUnderlyingWithFeeInsideTolerance() public {
        uint256 shares = _vaultShares(1_000e18);
        IShieldV1.MandateParams memory rp = _params(REDEEM, address(vault), _redeemCfg(), 0);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(rp);
        address clone = exec.nextClone(id);
        IExecutorV1.Call memory k = IExecutorV1.Call({
            target: address(vault),
            spender: address(0),
            approveToken: address(0),
            approveAmount: 0,
            claimStep: false,
            data: abi.encodeCall(IERC4626.redeem, (shares / 2, clone, clone))
        });
        vault.setExitFee(30); // 0.3%, inside 0.5%
        uint256 uBefore = usdc.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, shares / 2, _route(k));
        assertEq(spent, shares / 2);
        assertGt(usdc.balanceOf(principal) - uBefore, 495e18);
        vault.setExitFee(100); // 1%, beyond tolerance
        address clone2 = exec.nextClone(id);
        bytes memory r2 = _route(
            IExecutorV1.Call({
                target: address(vault),
                spender: address(0),
                approveToken: address(0),
                approveAmount: 0,
                claimStep: false,
                data: abi.encodeCall(IERC4626.redeem, (shares / 4, clone2, clone2))
            })
        );
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, shares / 4, r2);
    }

    function _redeemRoute(uint256 shares, address clone) internal view returns (bytes memory) {
        return _route(
            IExecutorV1.Call({
                target: address(vault),
                spender: address(0),
                approveToken: address(0),
                approveAmount: 0,
                claimStep: false,
                data: abi.encodeCall(IERC4626.redeem, (shares, clone, clone))
            })
        );
    }

    /// Round 7: the floor keeps only its lower edge at a firing, so a vault that grew
    /// (here a 20% donation) is withdrawn from, and the owner receives the grown value.
    function test_redeemFloorLetsGrowthThrough() public {
        uint256 shares = _vaultShares(1_000e18);
        IShieldV1.MandateParams memory rp = _params(REDEEM, address(vault), _redeemCfg(), 0);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(rp);
        usdc.mint(address(vault), 200e18);
        uint256 before = usdc.balanceOf(principal);
        bytes memory r = _redeemRoute(shares / 2, exec.nextClone(id));
        vm.prank(agent);
        shield.fire(id, shares / 2, r);
        assertApproxEqAbs(usdc.balanceOf(principal) - before, 600e18, 1);
    }

    /// The owner's floor refuses a withdrawal once the sample is worth more than the
    /// band below its value at signing (here a 20% loss against a 5% band).
    function test_redeemFloorStopsAWithdrawalBelowIt() public {
        uint256 shares = _vaultShares(1_000e18);
        IShieldV1.MandateParams memory rp = _params(REDEEM, address(vault), _redeemCfg(), 0);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(rp);
        uint256 signed = vault.convertToAssets(1_000e18); // the sample as signed: nothing moved since
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), 200e18);
        uint256 current = vault.convertToAssets(1_000e18);
        bytes memory r = _redeemRoute(shares / 2, exec.nextClone(id));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, signed, current));
        shield.fire(id, shares / 2, r);
    }

    /// No floor (the default the app signs): a withdrawal at a loss goes through, paid at
    /// the vault's own quote less the slippage, into the owner's wallet only.
    function test_redeemWithoutFloorWithdrawsAtALoss() public {
        uint256 shares = _vaultShares(1_000e18);
        GenericExecutorV1.Config memory c = _redeemCfg();
        c.signedShares = 0;
        c.signedAssets = 0;
        c.sanityBandBps = 0;
        IShieldV1.MandateParams memory p = _params(REDEEM, address(vault), c, 0);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), 200e18);
        uint256 before = usdc.balanceOf(principal);
        bytes memory r = _redeemRoute(shares / 2, exec.nextClone(id));
        vm.prank(agent);
        shield.fire(id, shares / 2, r);
        assertApproxEqAbs(usdc.balanceOf(principal) - before, 400e18, 1);
    }

    /// Without a floor nothing about a sample may be signed: no decorative numbers.
    function test_redeemWithoutFloorRefusesASignedSample() public {
        _vaultShares(1_000e18);
        GenericExecutorV1.Config memory c = _redeemCfg();
        c.sanityBandBps = 0;
        IShieldV1.MandateParams memory p = _params(REDEEM, address(vault), c, 0);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:sanity"));
        shield.registerMandate(p);
    }

    // -------------------------------------------------------------------- repay

    function _repayCfg() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(market), spender: address(market)});
        c.sweepSet = new address[](0);
        c.tokenOut = address(usdc);
        c.market = address(market);
        c.collateralTarget = address(market);
        c.maxSlippageBps = 10;
        c.debtDescriptor = dDebt;
        c.collateralDescriptor = dColl;
    }

    function _repayCall(uint256 amount) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call({
            target: address(market),
            spender: address(market),
            approveToken: address(usdc),
            approveAmount: amount,
            claimStep: false,
            data: abi.encodeCall(MockMarket.repay, (principal, amount))
        });
    }

    function test_repayDebtDownCollateralPreserved() public {
        market.setDebt(principal, 500e18);
        market.setCollateral(principal, 900e18);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(_params(REPAY, address(usdc), _repayCfg(), 0));
        vm.prank(agent);
        uint256 spent = shield.fire(id, 200e18, _route(_repayCall(200e18)));
        assertEq(spent, 200e18);
        assertEq(market.debtOf(principal), 300e18);
        // the venue that quietly halves collateral is caught
        market.setSteal(true);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(_repayCall(100e18)));
        market.setSteal(false);
        // a route that spends without reducing the debt (pays someone else's debt) is caught
        IExecutorV1.Call memory k = _repayCall(100e18);
        k.data = abi.encodeCall(MockMarket.repay, (address(0xBAD), 100e18));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, _route(k));
    }

    function test_configRefusesLooseSlippageWithoutOverride() public {
        GenericExecutorV1.Config memory c = _cfg();
        c.maxSlippageBps = 300;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "maxSlippageBps"));
        shield.registerMandate(_params(TRANSFORM, address(usdc), c, 0));
        c.slippageOverride = true;
        vm.prank(principal);
        shield.registerMandate(_params(TRANSFORM, address(usdc), c, 0));
    }

    // ------------------------------------------- round 12: any of several outputs

    /// A second output token at twice weth's price, so the value sums are not 1:1.
    function _wbtc() internal returns (MockToken wbtc) {
        wbtc = new MockToken();
        oracle.set(address(wbtc), 2e8);
        _review(address(weth));
        _review(address(wbtc));
    }

    /// Round 13 (G12-H2): several outputs must be tokens the registry bound a
    /// fresh round for. Bind one for `token` (a mock Chainlink feed, fresh now).
    function _review(address token) internal {
        MockFeed f = new MockFeed();
        f.set(1, 1e8, vm.getBlockTimestamp(), 1);
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(f);
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.word = 1;
        d.isSigned = true;
        d.mustBePositive = true;
        d.decimals = 8;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = 86_400;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
        vm.startPrank(admin);
        registry.setPriceRound(token, registry.listDescriptor(d), address(f));
        vm.stopPrank();
    }

    /// The signed price rules for [usdc, weth, `out`], as the registry binds them now.
    function _pinned3(address out) internal view returns (ExprLib.PriceRound[] memory) {
        address[] memory t = new address[](3);
        t[0] = address(usdc);
        t[1] = address(weth);
        t[2] = out;
        return PinnedPrices.pin(IShieldRegistryV1(address(registry)), t);
    }

    function _anyCfg(MockToken wbtc, bool floors) internal view returns (GenericExecutorV1.Config memory c) {
        c = _cfg();
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output({token: address(wbtc), floor: floors ? 40e18 : 0});
        if (floors) {
            c.rateKind = uint8(GenericExecutorV1.RateKind.Floor);
            c.rateOrFloor = 100e18; // 100 weth settles a whole firing, or 40 wbtc, or shares of each
            c.oracle = address(0);
            c.maxSlippageBps = 0;
        } else {
            c.prices = _pinned3(address(wbtc));
        }
    }

    function _swapTo(address tokenOut, uint256 amountIn, address to)
        internal
        view
        returns (IExecutorV1.Call memory k)
    {
        k = _swapCall(amountIn, to);
        k.data = abi.encodeCall(MockDex.swap, (address(usdc), tokenOut, amountIn, to));
    }

    function _route2(IExecutorV1.Call memory a, IExecutorV1.Call memory b)
        internal
        pure
        returns (bytes memory)
    {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](2);
        calls[0] = a;
        calls[1] = b;
        return abi.encode(calls);
    }

    function _register(GenericExecutorV1.Config memory c) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(_params(TRANSFORM, address(usdc), c, 0));
    }

    /// Austin, 24 Sep: a mandate bounds the loss, not the route. The route may
    /// deliver only the second signed output; the oracle judges its value.
    function test_r12_theOracleJudgesWhicheverOutputArrived() public {
        MockToken wbtc = _wbtc();
        bytes32 id = _register(_anyCfg(wbtc, false));
        dex.setRate(0.5e18); // 100 usdc ($100) -> 50 wbtc ($100)
        address clone = exec.nextClone(id);
        uint256 wethBefore = weth.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e18, _route(_swapTo(address(wbtc), 100e18, clone)));
        assertEq(spent, 100e18);
        assertEq(wbtc.balanceOf(principal), 50e18, "the second output reached the owner");
        assertEq(weth.balanceOf(principal), wethBefore, "tokenOut untouched");
        assertEq(wbtc.balanceOf(clone), 0, "swept");
    }

    function test_r12_aLossIsRefusedWhicheverOutputTheRouteChose() public {
        MockToken wbtc = _wbtc();
        bytes32 id = _register(_anyCfg(wbtc, false));
        dex.setRate(0.5e18);
        dex.setSkim(100); // 1% short, the mandate allows 0.5%
        uint256 before = usdc.balanceOf(principal);
        address clone = exec.nextClone(id);
        // $99 of value against $100 sold less 0.5%, WAD-scaled in the oracle's base currency
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, 99e26, 995e25)
            )
        );
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapTo(address(wbtc), 100e18, clone)));
        assertEq(usdc.balanceOf(principal), before, "nothing left the owner");
    }

    function test_r12_aSplitAcrossOutputsCountsItsWholeValue() public {
        MockToken wbtc = _wbtc();
        // Two signed venues: one pays weth 1:1, the other wbtc at half (both fair).
        MockDex half = new MockDex();
        half.setRate(0.5e18);
        GenericExecutorV1.Config memory c = _anyCfg(wbtc, false);
        c.venues = new GenericExecutorV1.Venue[](2);
        c.venues[0] = GenericExecutorV1.Venue({target: address(dex), spender: address(dex)});
        c.venues[1] = GenericExecutorV1.Venue({target: address(half), spender: address(half)});
        bytes32 id = _register(c);
        address clone = exec.nextClone(id);
        // 60 usdc -> 60 weth ($60) and 40 usdc -> 20 wbtc ($40), in one firing
        IExecutorV1.Call memory a = _swapTo(address(weth), 60e18, clone);
        IExecutorV1.Call memory b = _swapTo(address(wbtc), 40e18, clone);
        b.target = address(half);
        b.spender = address(half);
        uint256 wethBefore = weth.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e18, _route2(a, b));
        assertEq(spent, 100e18);
        assertEq(weth.balanceOf(principal) - wethBefore, 60e18);
        assertEq(wbtc.balanceOf(principal), 20e18);
    }

    function test_r12_floorsCountEachOutputsShareAndTheSharesAddUp() public {
        MockToken wbtc = _wbtc();
        // Only wbtc: 40 wbtc is a whole firing.
        bytes32 id = _register(_anyCfg(wbtc, true));
        dex.setRate(0.4e18);
        address clone = exec.nextClone(id);
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapTo(address(wbtc), 100e18, clone)));
        assertEq(wbtc.balanceOf(principal), 40e18);
        // One unit short of the floor: refused.
        dex.setSkim(1);
        clone = exec.nextClone(id);
        vm.expectRevert();
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapTo(address(wbtc), 100e18, clone)));
    }

    function test_r12_floorSharesSplitAcrossOutputsAddUpToOneFiring() public {
        MockToken wbtc = _wbtc();
        MockDex half = new MockDex();
        half.setRate(0.4e18);
        GenericExecutorV1.Config memory c = _anyCfg(wbtc, true);
        c.venues = new GenericExecutorV1.Venue[](2);
        c.venues[0] = GenericExecutorV1.Venue({target: address(dex), spender: address(dex)});
        c.venues[1] = GenericExecutorV1.Venue({target: address(half), spender: address(half)});
        bytes32 id = _register(c);
        // 50 weth (half of its 100 floor) + 20 wbtc (half of its 40 floor): one whole firing.
        address clone = exec.nextClone(id);
        IExecutorV1.Call memory a = _swapTo(address(weth), 50e18, clone);
        IExecutorV1.Call memory b = _swapTo(address(wbtc), 50e18, clone);
        b.target = address(half);
        b.spender = address(half);
        vm.prank(agent);
        shield.fire(id, 100e18, _route2(a, b));
        // 49 weth + 20 wbtc is 0.49 + 0.5: short.
        clone = exec.nextClone(id);
        a = _swapTo(address(weth), 49e18, clone);
        b = _swapTo(address(wbtc), 50e18, clone);
        b.target = address(half);
        b.spender = address(half);
        vm.expectRevert();
        vm.prank(agent);
        shield.fire(id, 99e18, _route2(a, b));
    }

    /// A fee-on-transfer output: the value check reads what reached the owner,
    /// after the token's own fee on the sweep, never what the route paid.
    function test_r12_aFeeOnTransferOutputIsJudgedOnWhatReachedTheOwner() public {
        MockFeeToken fee = new MockFeeToken();
        oracle.set(address(fee), 1e8);
        GenericExecutorV1.Config memory c = _cfg();
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output({token: address(fee), floor: 0});
        _review(address(weth));
        _review(address(fee));
        c.prices = _pinned3(address(fee));
        bytes32 id = _register(c); // 0.5% slippage
        address clone = exec.nextClone(id);
        IExecutorV1.Call memory k = _swapTo(address(fee), 100e18, clone);
        // The route pays 100 at par; the sweep's 1% fee leaves 99 with the owner.
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, 99e26, 995e25)
            )
        );
        vm.prank(agent);
        shield.fire(id, 100e18, _route(k));
    }

    function test_r12_admissionRefusesWhatTheRuleCannotJudge() public {
        MockToken wbtc = _wbtc();
        MockToken unpriced = new MockToken();
        GenericExecutorV1.Config memory c;
        bytes memory moreOuts = abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "moreOuts");

        // The asset, tokenOut or a repeat as a further output.
        c = _anyCfg(wbtc, false);
        c.moreOuts[0].token = address(usdc);
        c.prices[2].token = address(usdc);
        _refused(c, TRANSFORM, moreOuts);
        c = _anyCfg(wbtc, false);
        c.moreOuts[0].token = address(weth);
        c.prices[2].token = address(weth);
        _refused(c, TRANSFORM, moreOuts);
        // A token Aave's oracle does not price, under the oracle rule.
        c = _anyCfg(wbtc, false);
        c.moreOuts[0].token = address(unpriced);
        c.prices[2].token = address(unpriced);
        _refused(c, TRANSFORM, moreOuts);
        // A floor under the oracle rule, and no floor under the floor rule.
        c = _anyCfg(wbtc, false);
        c.moreOuts[0].floor = 1;
        _refused(c, TRANSFORM, moreOuts);
        c = _anyCfg(wbtc, true);
        c.moreOuts[0].floor = 0;
        _refused(c, TRANSFORM, moreOuts);
        // The fixed rate cannot judge several outputs.
        c = _anyCfg(wbtc, true);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Fixed);
        c.rateOrFloor = 1e18;
        _refused(c, TRANSFORM, moreOuts);
        // More than four further outputs.
        c = _anyCfg(wbtc, true);
        c.moreOuts = new GenericExecutorV1.Output[](5);
        for (uint256 i = 0; i < 5; i++) {
            MockToken t = new MockToken();
            c.moreOuts[i] = GenericExecutorV1.Output({token: address(t), floor: 1});
        }
        _refused(c, TRANSFORM, moreOuts);
        // Only a transform delivers outputs.
        c = _cfg();
        c.recipient = address(0xBEEF);
        c.venues = new GenericExecutorV1.Venue[](0);
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output({token: address(wbtc), floor: 0});
        _refused(c, TRANSFER, moreOuts);
        // The price rules must cover every output, in order.
        c = _anyCfg(wbtc, false);
        ExprLib.PriceRound[] memory two = new ExprLib.PriceRound[](2);
        two[0] = c.prices[0];
        two[1] = c.prices[1];
        c.prices = two;
        _refused(
            c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "price:round")
        );
        // An output is never a venue.
        c = _anyCfg(wbtc, false);
        c.venues[0] = GenericExecutorV1.Venue({target: address(wbtc), spender: address(dex)});
        _refused(
            c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "venue:target")
        );
    }

    function _refused(GenericExecutorV1.Config memory c, bytes32 action, bytes memory err) internal {
        IShieldV1.MandateParams memory p = _params(action, address(usdc), c, 0);
        vm.prank(principal);
        vm.expectRevert(err);
        shield.registerMandate(p);
    }
}

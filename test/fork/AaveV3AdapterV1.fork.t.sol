// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Shield v1 on a fork of X Layer: the Aave adapter on the v1 interface, driven
/// through the v1 core with a health-factor trigger tree read through the
/// descriptor catalog. Same fixture as the v0.1 fork test (block 70,752,723,
/// xETH collateral, USD-T0 debt, health factor about 1.5).
/// RPC: `XLAYER_RPC_URL`, defaulting to the public endpoint.
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveOracle, IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {AaveV3AdapterV1} from "contracts/v1/AaveV3AdapterV1.sol";
import {MockRouter} from "../mocks/MockRouter.sol";

contract AaveV3AdapterV1ForkTest is Test {
    uint256 internal constant FORK_BLOCK = 70_752_723;
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant A_USDT0 = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    address internal constant V_USDT0 = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;
    bytes32 internal constant SUPPLY = keccak256("aave-v3.supply");
    bytes32 internal constant REPAY = keccak256("aave-v3.repay");
    bytes32 internal constant RWC = keccak256("aave-v3.repayWithCollateral");

    ShieldV1 internal shield;

    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    AaveV3AdapterV1 internal adapter;
    MockRouter internal router;
    IPool internal pool = IPool(POOL);
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    uint256 internal constant COLLATERAL = 0.05e18;
    uint256 internal constant DEBT = 60e6;
    uint48 internal validUntil;
    bytes32 internal dHf; // aave.accountData.hf

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        assertEq(block.chainid, 196);
        validUntil = uint48(block.timestamp + 30 days);
        registry = new ShieldRegistryV1(address(this));
        shield = new ShieldV1(registry, 10);
        ev = new ExpressionEvaluator(registry);
        adapter = new AaveV3AdapterV1(address(shield), pool);
        router = new MockRouter();
        registry.setExecutor(address(adapter), true);
        registry.setEvaluator(address(ev), true);
        dHf = registry.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.PerAddress,
                target: POOL,
                selector: IPool.getUserAccountData.selector,
                argCount: 1,
                subjectArg: 0,
                subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
                word: 5,
                isSigned: false,
                mustBePositive: false,
                decimals: 18,
                freshness: IDescriptors.Freshness.None,
                maxAge: 0,
                gasStipend: 500_000,
                copyBytes: 192,
                unboundedTop: true
            })
        );
        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(principal, 100e6);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(address(router), 10_000e6);
        vm.startPrank(principal);
        IERC20(XETH).approve(POOL, type(uint256).max);
        pool.supply(XETH, COLLATERAL, principal, 0);
        pool.borrow(USDT0, DEBT, 2, 0, principal);
        IERC20(USDT0).approve(address(shield), type(uint256).max);
        IERC20(A_XETH).approve(address(shield), type(uint256).max);
        IERC20(XETH).approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- helpers

    function _healthFactor(address user) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(user);
    }

    /// health factor of the principal < threshold, as a v1 tree through the catalog
    function _hfBelow(uint256 threshold) internal view returns (bytes memory) {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dHf,
            target: POOL,
            args: abi.encode(principal),
            subject: ExprLib.Subject.Principal,
            decimals: 18
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: threshold, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.LT), a: 0, b: 1});
        return abi.encode(r, n);
    }

    function _params(bytes32 action, address asset, uint256 txCap, uint256 lifetime, bytes memory trigger)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p.agent = agent;
        p.executor = address(adapter);
        p.evaluator = address(ev);
        p.action = action;
        p.asset = asset;
        p.maxTransactionValue = txCap;
        p.maxCumulativeValue = lifetime;
        p.validFrom = 0;
        p.validUntil = validUntil;
        p.maxFeeBps = 10;
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.trigger = trigger;
    }

    function _register(IShieldV1.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _swapCalldata(uint256 amountIn, uint256 amountOut, address to)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(MockRouter.swap, (XETH, amountIn, USDT0, amountOut, to));
    }

    function _fairUsdt0(uint256 xethAmount) internal view returns (uint256) {
        IAaveOracle oracle = IAaveOracle(ORACLE);
        return (xethAmount * oracle.getAssetPrice(XETH) * 1e6) / (oracle.getAssetPrice(USDT0) * 1e18);
    }

    function _rwcConfig(uint256 targetHf) internal view returns (bytes memory) {
        return abi.encode(
            uint8(1),
            AaveV3AdapterV1.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: targetHf,
                maxSlippageBps: 100,
                slippageOverride: false,
                router: address(router),
                spender: address(router),
                prices: PinnedPrices.pin(IShieldRegistryV1(address(registry)), XETH, USDT0)
            })
        );
    }

    function _assertNothingLeftBehind() internal view {
        assertEq(IERC20(XETH).balanceOf(address(adapter)), 0, "adapter xETH");
        assertEq(IERC20(USDT0).balanceOf(address(adapter)), 0, "adapter USDT0");
        assertEq(IERC20(A_XETH).balanceOf(address(adapter)), 0, "adapter aXETH");
        assertEq(IERC20(USDT0).balanceOf(address(shield)), 0, "shield USDT0");
        assertEq(IERC20(XETH).allowance(address(adapter), address(router)), 0, "approval xETH->spender");
    }

    // ---------------------------------------------------------------- cases

    function test_repay_realDebtWithATriggerTreeThroughTheCatalog() public {
        IShieldV1.MandateParams memory p = _params(REPAY, USDT0, 20e6, 40e6, _hfBelow(1.6e18));
        bytes32 id = _register(p);
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 hfBefore = _healthFactor(principal);
        assertLt(hfBefore, 1.6e18, "fixture: trigger is true");
        (bool ok,) = shield.canFireBy(id, agent, 10e6);
        assertTrue(ok);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 10e6, "");
        assertEq(spent, 10e6); // fee recipient unset: no fee
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDT0).balanceOf(principal), 10e6, 2, "debt fell by what was repaid"
        );
        assertGt(_healthFactor(principal), hfBefore);
        assertEq(shield.getMandate(id).cumulativeUsed, 10e6);
        _assertNothingLeftBehind();
        // The repay lifted the health factor past the trigger: refused now.
        assertGe(_healthFactor(principal), 1.6e18);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.TRIGGER_NOT_MET
            )
        );
        shield.fire(id, 10e6, "");
    }

    /// Round 7: a wallet with no Aave debt reads a health factor of type(uint256).max from
    /// the real pool. That now counts as the top of the int256 range, so a health-factor
    /// trigger registers (it used to revert ValueOutOfRange) and simply reads "not below".
    function test_healthFactorTriggerRegistersForAWalletWithNoDebt() public {
        address fresh = makeAddr("no-debt");
        (,,,,, uint256 hf) = pool.getUserAccountData(fresh);
        assertEq(hf, type(uint256).max);
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dHf,
            target: POOL,
            args: abi.encode(fresh),
            subject: ExprLib.Subject.Principal,
            decimals: 18
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: 1.6e18, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.LT), a: 0, b: 1});
        IShieldV1.MandateParams memory p = _params(SUPPLY, XETH, 0.01e18, 0.02e18, abi.encode(r, n));
        vm.prank(fresh);
        bytes32 id = shield.registerMandate(p);
        assertEq(shield.getMandate(id).principal, fresh);
        // "Below 1.6" is false with no debt: the value is the top of the range, never negative.
        assertFalse(ev.judgeTrigger(p.trigger, fresh, shield.getMandate(id).triggerSigned, 0.01e18));
    }

    function test_supply_raisesTheOwnersATokenBalance() public {
        bytes32 id = _register(_params(SUPPLY, XETH, 0.01e18, 0.02e18, ""));
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 0.01e18, "");
        assertEq(spent, 0.01e18);
        assertApproxEqAbs(IERC20(A_XETH).balanceOf(principal) - aBefore, 0.01e18, 2);
        _assertNothingLeftBehind();
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0.01e18, hex"01"); // supply takes no route
    }

    function test_repayWithCollateral_bringsTheHealthFactorToTarget() public {
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.01e18, 0.02e18, _hfBelow(1.6e18));
        p.actionConfig = _rwcConfig(1.7e18);
        bytes32 id = _register(p);
        uint256 slice = 0.008e18;
        uint256 amountIn = slice - 1_000;
        uint256 amountOut = (_fairUsdt0(amountIn) * 9_950) / 10_000;
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        bytes memory route = _swapCalldata(amountIn, amountOut, address(adapter));
        vm.prank(agent);
        uint256 spent = shield.fire(id, slice, route);
        assertApproxEqAbs(spent, amountIn, 2, "what was sold is what was spent");
        assertApproxEqAbs(
            aBefore - IERC20(A_XETH).balanceOf(principal), amountIn, 2, "only the sold part left"
        );
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDT0).balanceOf(principal), amountOut, 2, "debt fell by the output"
        );
        assertGe(_healthFactor(principal), 1.7e18);
        _assertNothingLeftBehind();
    }

    function test_repayWithCollateral_partialSaleGoesBackIntoThePosition() public {
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.01e18, 0.02e18, _hfBelow(1.6e18));
        p.actionConfig = _rwcConfig(10e18);
        bytes32 id = _register(p);
        uint256 sliver = 0.0005e18;
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        uint256 xethBefore = IERC20(XETH).balanceOf(principal);
        bytes memory route = _swapCalldata(sliver, _fairUsdt0(sliver), address(adapter));
        vm.prank(agent);
        uint256 spent = shield.fire(id, 0.008e18, route);
        assertApproxEqAbs(spent, sliver, 2);
        assertApproxEqAbs(
            aBefore - IERC20(A_XETH).balanceOf(principal), sliver, 2, "the rest is back in the position"
        );
        assertEq(IERC20(XETH).balanceOf(principal), xethBefore, "no collateral landed in the wallet");
        _assertNothingLeftBehind();
    }

    function test_repayWithCollateral_suspendedRouterIsRefused() public {
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.01e18, 0.02e18, _hfBelow(1.6e18));
        p.actionConfig = _rwcConfig(10e18);
        bytes32 id = _register(p);
        registry.setEnforcer(makeAddr("enforcer"), true);
        vm.prank(makeAddr("enforcer"));
        registry.suspend(address(router));
        bytes memory route = _swapCalldata(0.0005e18, _fairUsdt0(0.0005e18), address(adapter));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0.008e18, route);
    }

    function test_repayWithCollateral_refusesLooseSlippageWithoutOverride() public {
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.01e18, 0.02e18, _hfBelow(1.6e18));
        p.actionConfig = abi.encode(
            uint8(1),
            AaveV3AdapterV1.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: 1.5e18,
                maxSlippageBps: 300,
                slippageOverride: false,
                router: address(router),
                spender: address(router),
                prices: PinnedPrices.pin(IShieldRegistryV1(address(registry)), XETH, USDT0)
            })
        );
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3AdapterV1.ConfigInvalid.selector, "maxSlippageBps"));
        shield.registerMandate(p);
    }

    // ------------------------------------------------- round 11: steps near 1

    /// Aave's HealthFactorLowerThanLiquidationThreshold(): an aToken transfer
    /// that would leave the sender under a health factor of 1.
    bytes4 internal constant AAVE_HF_BELOW_ONE = 0x6679996d;

    /// Borrow 90% of what the position still allows: health factor near 1.1.
    function _borrowToNearOne() internal {
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 availableBase,,,) = pool.getUserAccountData(principal);
        vm.prank(principal);
        pool.borrow(USDT0, (availableBase * 90) / 10_000, 2, 0, principal); // base 8 decimals, USDT0 6
    }

    /// The slice that reaches `target` in one firing (sell c, repay c):
    /// c >= (t*D - C*LT) / (t - LT), in xETH units.
    function _sliceToTarget(uint256 target) internal view returns (uint256) {
        (uint256 cBase, uint256 dBase,, uint256 ltBps,,) = pool.getUserAccountData(principal);
        uint256 lt = ltBps * 1e14;
        uint256 saleBase = (target * dBase - cBase * lt) / (target - lt);
        return (saleBase * 1e18) / IAaveOracle(ORACLE).getAssetPrice(XETH);
    }

    /// The app's sizing (lib/shield/sizing.ts): the largest slice whose pull,
    /// with its 0.1% fee reserve, leaves the owner at a health factor of 1.01.
    function _pullLimitedSlice() internal view returns (uint256) {
        // forge-lint: disable-next-line(unused-return)
        (, uint256 dBase,,,, uint256 hf) = pool.getUserAccountData(principal);
        uint256 units = (((hf - 1.01e18) * dBase) / 1e18) * 1e18 / IAaveOracle(ORACLE).getAssetPrice(XETH);
        return (units * 10_000) / 10_010;
    }

    /// R11 (fixed): near a health factor of 1 the slice that reaches the
    /// target cannot leave the position (Aave refuses the pull), and the
    /// adapter refused any firing that stopped short of the target, so the
    /// mandate never fired when the owner needed it most. Now each firing
    /// lifts the health factor and the next firings step the rest.
    function test_fixNearOneFiringsStepToTheTarget() public {
        _borrowToNearOne();
        assertLt(_healthFactor(principal), 1.2e18, "fixture near 1");
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.05e18, 0.2e18, _hfBelow(1.8e18));
        p.actionConfig = _rwcConfig(1.8e18);
        bytes32 id = _register(p);

        uint256 oneShot = _sliceToTarget(1.8e18);
        assertGt(oneShot, _pullLimitedSlice(), "one firing cannot reach the target");
        bytes memory wholeRoute =
            _swapCalldata(oneShot, (_fairUsdt0(oneShot) * 9_950) / 10_000, address(adapter));
        vm.prank(agent);
        vm.expectRevert(AAVE_HF_BELOW_ONE);
        shield.fire(id, oneShot, wholeRoute);

        uint256 firings;
        while (_healthFactor(principal) < 1.8e18) {
            uint256 before = _healthFactor(principal);
            uint256 slice = _pullLimitedSlice();
            uint256 amountIn = slice - 1_000;
            bytes memory route =
                _swapCalldata(amountIn, (_fairUsdt0(amountIn) * 9_950) / 10_000, address(adapter));
            vm.prank(agent);
            shield.fire(id, slice, route);
            assertGt(_healthFactor(principal), before, "every firing lifts the health factor");
            _assertNothingLeftBehind();
            firings++;
            assertLe(firings, 8, "the steps converge");
        }
        assertGt(firings, 1, "it took more than one firing");
    }

    /// R11: the target is a gate as well. At or over it the adapter refuses,
    /// even when the owner's trigger does not read the health factor.
    function test_fixAtTheTargetTheAdapterRefuses() public {
        assertGt(_healthFactor(principal), 1.3e18, "fixture over the target");
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.01e18, 0.02e18, "");
        p.actionConfig = _rwcConfig(1.2e18);
        bytes32 id = _register(p);
        uint256 sold = 0.0005e18;
        bytes memory route = _swapCalldata(sold, _fairUsdt0(sold), address(adapter));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(
                    AaveV3AdapterV1.OutcomeFailed.selector, "health factor already at target"
                )
            )
        );
        shield.fire(id, 0.008e18, route);
    }
}

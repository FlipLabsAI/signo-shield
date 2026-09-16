// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IAaveOracle, IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {MockRouter} from "../mocks/MockRouter.sol";

/// The Aave adapter against the real Aave V3 market on X Layer (chain 196),
/// at a pinned block. A borrower that is NOT the caller gets its real debt
/// repaid by an agent through the Shield, and every boundary case reverts
/// with its reason code.
///
/// RPC: `XLAYER_RPC_URL`, defaulting to the public endpoint. The block is
/// pinned so a judge's run and ours read the same state.
contract AaveV3AdapterForkTest is Test {
    uint256 internal constant FORK_BLOCK = 70_752_723;
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant A_USDT0 = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    /// Aave V3 custom error selector: HealthFactorLowerThanLiquidationThreshold().
    bytes4 internal constant HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD = 0x6679996d;
    address internal constant V_USDT0 = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;

    SignoShield internal shield;
    ConditionModule internal conditions;
    AaveV3Adapter internal adapter;
    MockRouter internal router;
    IPool internal pool = IPool(POOL);

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal enforcer = makeAddr("enforcer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant COLLATERAL = 0.05e18; // about 120 USD of xETH at the pinned block
    uint256 internal constant DEBT = 60e6; // 60 USD-T0, health factor about 1.5
    uint48 internal validUntil;

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        assertEq(block.chainid, 196);
        validUntil = uint48(block.timestamp + 30 days);

        conditions = new ConditionModule();
        shield = new SignoShield(address(this), conditions, 10); // the launch fee, 10 bps
        adapter = new AaveV3Adapter(address(shield), pool);
        router = new MockRouter();
        shield.setAdapter(address(adapter), true);
        shield.setEnforcer(enforcer, true);

        // The aToken contracts hold the underlying they were supplied; borrow from them for the fixture.
        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(principal, 100e6);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(address(router), 10_000e6);

        // The demo position: xETH collateral, USD-T0 debt, health factor about 1.5.
        vm.startPrank(principal);
        IERC20(XETH).approve(POOL, type(uint256).max);
        pool.supply(XETH, COLLATERAL, principal, 0);
        pool.borrow(USDT0, DEBT, 2, 0, principal);
        // The two grants the product asks for: the Shield may pull the debt
        // asset (repay), the collateral aToken (repay-with-collateral) and
        // idle xETH (supply). Nothing is granted to the agent.
        IERC20(USDT0).approve(address(shield), type(uint256).max);
        IERC20(A_XETH).approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- helpers

    function _healthFactor(address user) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(user);
    }

    function _hfBelow(uint256 threshold) internal view returns (ICondition.Condition memory) {
        return ICondition.Condition({
            target: POOL,
            callData: abi.encodeCall(IPool.getUserAccountData, (principal)),
            wordOffset: 5,
            comparator: ICondition.Comparator.LessThan,
            threshold: threshold
        });
    }

    function _noCondition() internal pure returns (ICondition.Condition memory c) {
        c.comparator = ICondition.Comparator.LessThan;
    }

    function _params(
        bytes32 action,
        address asset,
        uint256 txCap,
        uint256 lifetime,
        ICondition.Condition memory cond
    ) internal view returns (ISignoShield.MandateParams memory p) {
        p.agent = agent;
        p.adapter = address(adapter);
        p.action = action;
        p.asset = asset;
        p.maxTransactionValue = txCap;
        p.maxCumulativeValue = lifetime;
        p.validFrom = 0;
        p.validUntil = validUntil;
        p.condition = cond;
        p.actionConfig = "";
    }

    function _register(ISignoShield.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _blocked(bytes32 id, ISignoShield.MandateReason r) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISignoShield.MandateBlocked.selector, id, r);
    }

    function _assertNothingLeftBehind() internal view {
        assertEq(IERC20(XETH).balanceOf(address(adapter)), 0, "adapter xETH");
        assertEq(IERC20(USDT0).balanceOf(address(adapter)), 0, "adapter USDT0");
        assertEq(IERC20(A_XETH).balanceOf(address(adapter)), 0, "adapter aXETH");
        assertEq(IERC20(XETH).balanceOf(address(shield)), 0, "shield xETH");
        assertEq(IERC20(USDT0).balanceOf(address(shield)), 0, "shield USDT0");
        assertEq(IERC20(A_XETH).balanceOf(address(shield)), 0, "shield aXETH");
        assertEq(IERC20(XETH).allowance(address(adapter), POOL), 0, "approval xETH->pool");
        assertEq(IERC20(USDT0).allowance(address(adapter), POOL), 0, "approval USDT0->pool");
        assertEq(IERC20(XETH).allowance(address(adapter), address(router)), 0, "approval xETH->spender");
    }

    /// The "agent's" swap calldata: sell `amountIn` xETH for `amountOut` USD-T0, paid to `to`.
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

    // --------------------------------------------------------------- repay

    /// DONE WHEN of FLIP-192: real debt, a borrower that is not the caller.
    function test_repay_repaysRealDebtForABorrowerThatIsNotTheCaller() public {
        bytes32 id = _register(_params(adapter.ACTION_REPAY(), USDT0, 20e6, 40e6, _hfBelow(1.6e18)));
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 walletBefore = IERC20(USDT0).balanceOf(principal);
        uint256 hfBefore = _healthFactor(principal);
        assertApproxEqAbs(debtBefore, DEBT, 1, "fixture debt");
        assertLt(hfBefore, 1.6e18, "fixture: trigger is true");

        (bool ok, ISignoShield.MandateReason r) = shield.canFire(id, 10e6);
        assertTrue(ok);
        assertEq(uint8(r), uint8(ISignoShield.MandateReason.OK));

        vm.prank(agent);
        uint256 spent = shield.fire(id, 10e6, "");

        assertEq(spent, 10e6);
        uint256 debtAfter = IERC20(V_USDT0).balanceOf(principal);
        assertApproxEqAbs(debtBefore - debtAfter, 10e6, 2, "debt fell by what was repaid");
        assertEq(walletBefore - IERC20(USDT0).balanceOf(principal), 10e6, "paid from the principal's wallet");
        assertGt(_healthFactor(principal), hfBefore, "health factor rose");
        assertEq(shield.getMandate(id).cumulativeUsed, 10e6);
        _assertNothingLeftBehind();

        // The repay lifted the health factor past the trigger: the same mandate is now refused.
        assertGe(_healthFactor(principal), 1.6e18);
        (ok, r) = shield.canFire(id, 10e6);
        assertFalse(ok);
        assertEq(uint8(r), uint8(ISignoShield.MandateReason.TRIGGER_NOT_MET));
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.TRIGGER_NOT_MET));
        shield.fire(id, 10e6, "");
    }

    /// With a recipient set, 10 bps of each firing goes to it and the rest repays.
    function test_repay_takesTheLaunchFeeWhenARecipientIsSet() public {
        address treasury = makeAddr("treasury");
        shield.setFeeRecipient(treasury);
        bytes32 id = _register(_params(adapter.ACTION_REPAY(), USDT0, 20e6, 40e6, _hfBelow(10e18)));
        assertEq(shield.getMandate(id).feeBps, 10);
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 walletBefore = IERC20(USDT0).balanceOf(principal);

        vm.prank(agent);
        uint256 spent = shield.fire(id, 10e6, "");

        assertEq(spent, 10e6, "fee plus repayment is what left the wallet");
        assertEq(IERC20(USDT0).balanceOf(treasury), 10_000, "10 bps of 10 USD-T0");
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDT0).balanceOf(principal), 10e6 - 10_000, 2, "the rest repaid"
        );
        assertEq(walletBefore - IERC20(USDT0).balanceOf(principal), 10e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 10e6, "the fee counts against the budget");
        _assertNothingLeftBehind();
    }

    /// Asking for more than is owed repays the debt and returns the rest.
    function test_repay_clampsToTheDebtAndRefundsTheRest() public {
        bytes32 id = _register(_params(adapter.ACTION_REPAY(), USDT0, 100e6, 100e6, _noCondition()));
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 walletBefore = IERC20(USDT0).balanceOf(principal);

        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e6, "");

        assertApproxEqAbs(spent, debtBefore, 1, "spent what was owed, not what was asked");
        assertEq(IERC20(V_USDT0).balanceOf(principal), 0, "debt cleared");
        assertEq(
            walletBefore - IERC20(USDT0).balanceOf(principal), spent, "only the repaid amount left the wallet"
        );
        assertEq(shield.getMandate(id).cumulativeUsed, spent, "budget reconciled to actual spend");
        _assertNothingLeftBehind();

        // Nothing left to repay: the adapter refuses rather than pulling funds for nothing.
        vm.prank(agent);
        vm.expectRevert(AaveV3Adapter.NoDebt.selector);
        shield.fire(id, 1e6, "");
    }

    /// The boundary set from the engineer brief, each with its reason code.
    function test_repay_boundariesRevertWithTheirReasonCodes() public {
        // A trigger that stays true as the debt shrinks, so only the bound under test can refuse.
        bytes32 id = _register(_params(adapter.ACTION_REPAY(), USDT0, 20e6, 40e6, _hfBelow(10e18)));
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);

        // Over the per-firing cap.
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_TX_CAP));
        shield.fire(id, 20e6 + 1, "");

        // Not the agent: the principal cannot fire its own mandate, nor can anyone else.
        vm.prank(principal);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.NOT_AGENT));
        shield.fire(id, 1e6, "");
        vm.prank(stranger);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.NOT_AGENT));
        shield.fire(id, 1e6, "");

        // Twice past the lifetime budget.
        vm.prank(agent);
        shield.fire(id, 20e6, "");
        vm.prank(agent);
        shield.fire(id, 20e6, "");
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP));
        shield.fire(id, 1e6, "");
        assertApproxEqAbs(debtBefore - IERC20(V_USDT0).balanceOf(principal), 40e6, 2);

        // Frozen agent.
        bytes32 id2 = _register(_params(adapter.ACTION_REPAY(), USDT0, 20e6, 40e6, _hfBelow(10e18)));
        vm.prank(enforcer);
        shield.freezeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(_blocked(id2, ISignoShield.MandateReason.AGENT_FROZEN));
        shield.fire(id2, 1e6, "");
        vm.prank(enforcer);
        shield.unfreezeAgent(agent);

        // Revoked by the principal.
        vm.prank(principal);
        shield.revokeMandate(id2);
        vm.prank(agent);
        vm.expectRevert(_blocked(id2, ISignoShield.MandateReason.REVOKED));
        shield.fire(id2, 1e6, "");

        // Expired.
        bytes32 id3 = _register(_params(adapter.ACTION_REPAY(), USDT0, 20e6, 40e6, _hfBelow(10e18)));
        vm.warp(uint256(validUntil) + 1);
        vm.prank(agent);
        vm.expectRevert(_blocked(id3, ISignoShield.MandateReason.EXPIRED));
        shield.fire(id3, 1e6, "");
        _assertNothingLeftBehind();
    }

    // -------------------------------------------------------------- supply

    function test_supply_raisesTheOwnersATokenBalance() public {
        vm.prank(principal);
        IERC20(XETH).approve(address(shield), type(uint256).max);
        bytes32 id = _register(_params(adapter.ACTION_SUPPLY(), XETH, 0.01e18, 0.02e18, _noCondition()));
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        uint256 walletBefore = IERC20(XETH).balanceOf(principal);
        uint256 hfBefore = _healthFactor(principal);

        vm.prank(agent);
        uint256 spent = shield.fire(id, 0.01e18, "");

        assertEq(spent, 0.01e18);
        assertApproxEqAbs(
            IERC20(A_XETH).balanceOf(principal) - aBefore, 0.01e18, 2, "aXETH rose by the amount"
        );
        assertEq(walletBefore - IERC20(XETH).balanceOf(principal), 0.01e18);
        assertGt(_healthFactor(principal), hfBefore, "more collateral, safer loan");
        _assertNothingLeftBehind();

        vm.prank(agent);
        vm.expectRevert(AaveV3Adapter.UnexpectedData.selector);
        shield.fire(id, 0.01e18, hex"01");
    }

    function test_supply_rejectsANonReserveAsset() public {
        ISignoShield.MandateParams memory p = _params(adapter.ACTION_SUPPLY(), A_XETH, 1, 1, _noCondition());
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ConfigInvalid.selector, "asset"));
        shield.registerMandate(p);
    }

    // ------------------------------------------------- repay with collateral

    function _rwcConfig(uint256 targetHf) internal view returns (bytes memory) {
        return abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: targetHf,
                maxSlippageBps: 100,
                router: address(router),
                spender: address(router)
            })
        );
    }

    function _registerRwc(uint256 targetHf, uint256 cap) internal returns (bytes32 id) {
        ISignoShield.MandateParams memory p =
            _params(adapter.ACTION_REPAY_WITH_COLLATERAL(), A_XETH, cap, cap * 2, _hfBelow(1.6e18));
        p.actionConfig = _rwcConfig(targetHf);
        id = _register(p);
    }

    function test_repayWithCollateral_bringsTheHealthFactorToTarget() public {
        bytes32 id = _registerRwc(1.7e18, 0.01e18);
        uint256 slice = 0.008e18; // about 19 USD of the 60 USD-T0 debt
        uint256 amountIn = slice - 1_000; // the router takes a hair less than withdrawn; the dust goes home
        uint256 amountOut = (_fairUsdt0(amountIn) * 9_950) / 10_000; // 50 bps under fair, inside the 1% bound
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        uint256 xethBefore = IERC20(XETH).balanceOf(principal);
        assertLt(_healthFactor(principal), 1.6e18, "fixture: trigger is true");

        vm.prank(agent);
        uint256 spent = shield.fire(id, slice, _swapCalldata(amountIn, amountOut, address(adapter)));

        assertApproxEqAbs(spent, slice, 2, "the whole slice was spent");
        assertApproxEqAbs(
            aBefore - IERC20(A_XETH).balanceOf(principal), slice, 2, "collateral slice left the position"
        );
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDT0).balanceOf(principal), amountOut, 2, "debt fell by the swap output"
        );
        assertEq(IERC20(XETH).balanceOf(principal) - xethBefore, 1_000, "unsold dust came home as xETH");
        assertGe(_healthFactor(principal), 1.7e18, "health factor at or above target");
        assertEq(shield.getMandate(id).cumulativeUsed, spent);
        _assertNothingLeftBehind();
    }

    function test_repayWithCollateral_refusesABadSwap() public {
        bytes32 id = _registerRwc(1.7e18, 0.01e18);
        uint256 slice = 0.008e18;
        uint256 amountIn = slice - 1_000;
        uint256 fair = _fairUsdt0(amountIn);
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);

        // 2% under fair: outside the 1% bound the principal signed. (The minimum
        // is computed on the withdrawn amount, a hair above amountIn, so match the selector.)
        bytes memory underpaid = _swapCalldata(amountIn, (fair * 9_800) / 10_000, address(adapter));
        vm.prank(agent);
        vm.expectPartialRevert(AaveV3Adapter.SwapOutputBelowMinimum.selector);
        shield.fire(id, slice, underpaid);

        // Output routed to a third party: nothing arrived, so nothing was repaid.
        bytes memory diverted = _swapCalldata(amountIn, fair, stranger);
        vm.prank(agent);
        vm.expectPartialRevert(AaveV3Adapter.SwapOutputBelowMinimum.selector);
        shield.fire(id, slice, diverted);

        // The router reverts: the firing reverts with it.
        bytes memory honest = _swapCalldata(amountIn, fair, address(adapter));
        router.setShouldRevert(true);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3Adapter.SwapFailed.selector,
                abi.encodeWithSignature("Error(string)", "router: no route")
            )
        );
        shield.fire(id, slice, honest);
        router.setShouldRevert(false);

        // A slice too small to reach the target: the outcome check reverts and the budget rolls back.
        uint256 tiny = 0.001e18;
        bytes memory tinySwap = _swapCalldata(tiny - 1_000, _fairUsdt0(tiny - 1_000), address(adapter));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3Adapter.OutcomeFailed.selector, "health factor below target")
        );
        shield.fire(id, tiny, tinySwap);

        assertEq(IERC20(V_USDT0).balanceOf(principal), debtBefore, "no debt moved");
        assertEq(IERC20(A_XETH).balanceOf(principal), aBefore, "no collateral moved");
        assertEq(shield.getMandate(id).cumulativeUsed, 0, "no budget used");
        _assertNothingLeftBehind();
    }

    /// Aave itself refuses a collateral transfer that would leave the position
    /// under-collateralised, so a slice that breaks the loan never reaches the swap.
    function test_repayWithCollateral_aaveRejectsASliceThatBreaksThePosition() public {
        bytes32 id = _registerRwc(1.7e18, 0.05e18);
        uint256 slice = 0.045e18; // leaves about 12 USD of collateral against 60 USD-T0 of debt
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        bytes memory swap = _swapCalldata(slice - 1_000, _fairUsdt0(slice - 1_000), address(adapter));
        vm.prank(agent);
        // Aave's HealthFactorLowerThanLiquidationThreshold(), raised by the aToken
        // transfer the Shield attempts, bubbled through SafeERC20.
        vm.expectRevert(HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD);
        shield.fire(id, slice, swap);
        assertEq(IERC20(A_XETH).balanceOf(principal), aBefore);
        assertEq(shield.getMandate(id).cumulativeUsed, 0);
    }

    function test_repayWithCollateral_configIsValidatedAtRegistration() public {
        ISignoShield.MandateParams memory p =
            _params(adapter.ACTION_REPAY_WITH_COLLATERAL(), XETH, 1, 1, _hfBelow(1.6e18));
        p.actionConfig = _rwcConfig(1.7e18);
        // The mandate's asset must be the collateral's aToken, not the underlying.
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ConfigInvalid.selector, "asset"));
        shield.registerMandate(p);

        p.asset = A_XETH;
        p.actionConfig = abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: 0.9e18,
                maxSlippageBps: 100,
                router: address(router),
                spender: address(router)
            })
        );
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ConfigInvalid.selector, "targetHealthFactor"));
        shield.registerMandate(p);

        p.actionConfig = abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: 1.7e18,
                maxSlippageBps: 1_001,
                router: address(router),
                spender: address(router)
            })
        );
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ConfigInvalid.selector, "maxSlippageBps"));
        shield.registerMandate(p);

        p.actionConfig = abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: 1.7e18,
                maxSlippageBps: 100,
                router: POOL,
                spender: address(router)
            })
        );
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ConfigInvalid.selector, "router"));
        shield.registerMandate(p);

        p.actionConfig = abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: 1.7e18,
                maxSlippageBps: 100,
                router: address(router),
                spender: stranger
            })
        );
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ConfigInvalid.selector, "spender"));
        shield.registerMandate(p);
    }

    /// The adapter answers to nobody but the Shield.
    function test_adapter_onlyShield() public {
        IShieldAdapter.Context memory ctx = IShieldAdapter.Context({
            mandateId: bytes32(0),
            principal: principal,
            agent: agent,
            action: adapter.ACTION_REPAY(),
            asset: USDT0,
            actionConfig: ""
        });
        vm.prank(agent);
        vm.expectRevert(AaveV3Adapter.NotShield.selector);
        adapter.execute(ctx, 1e6, "");
    }
}

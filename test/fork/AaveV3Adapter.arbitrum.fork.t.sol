// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IAaveOracle, IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {MockRouter} from "../mocks/MockRouter.sol";

/// The same adapter against Aave V3 on Arbitrum One (chain 42161), for the
/// Arbitrum Open House entry: WETH collateral, USDC debt, at a pinned block.
///
/// RPC: `ARBITRUM_RPC_URL`, defaulting to a public archive endpoint (the
/// official arb1 endpoint keeps only a few thousand blocks of state, too few
/// to pin against).
contract AaveV3AdapterArbitrumForkTest is Test {
    uint256 internal constant FORK_BLOCK = 505_617_500;
    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant A_WETH = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant V_USDC = 0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6;

    SignoShield internal shield;
    ConditionModule internal conditions;
    AaveV3Adapter internal adapter;
    MockRouter internal router;
    IPool internal pool = IPool(POOL);

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal enforcer = makeAddr("enforcer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant COLLATERAL = 0.05e18; // about 120 USD of WETH at the pinned block
    uint256 internal constant DEBT = 60e6; // 60 USDC, health factor about 1.68 (LT 84%)
    uint48 internal validUntil;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ARBITRUM_RPC_URL", string("https://arbitrum-one.public.blastapi.io")), FORK_BLOCK
        );
        assertEq(block.chainid, 42_161);
        validUntil = uint48(block.timestamp + 30 days);

        conditions = new ConditionModule();
        shield = new SignoShield(address(this), conditions, 10);
        adapter = new AaveV3Adapter(address(shield), pool);
        router = new MockRouter();
        shield.setAdapter(address(adapter), true);
        shield.setEnforcer(enforcer, true);

        vm.prank(A_WETH);
        IERC20(WETH).transfer(principal, 1e18);
        vm.prank(A_USDC);
        IERC20(USDC).transfer(principal, 100e6);
        vm.prank(A_USDC);
        IERC20(USDC).transfer(address(router), 10_000e6);

        vm.startPrank(principal);
        IERC20(WETH).approve(POOL, type(uint256).max);
        pool.supply(WETH, COLLATERAL, principal, 0);
        pool.borrow(USDC, DEBT, 2, 0, principal);
        IERC20(USDC).approve(address(shield), type(uint256).max);
        IERC20(A_WETH).approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

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
        p.validUntil = validUntil;
        p.condition = cond;
    }

    function _register(ISignoShield.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _blocked(bytes32 id, ISignoShield.MandateReason r) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISignoShield.MandateBlocked.selector, id, r);
    }

    function _assertNothingLeftBehind() internal view {
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "adapter WETH");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter USDC");
        assertEq(IERC20(A_WETH).balanceOf(address(adapter)), 0, "adapter aWETH");
        assertEq(IERC20(USDC).balanceOf(address(shield)), 0, "shield USDC");
        assertEq(IERC20(WETH).allowance(address(adapter), POOL), 0);
        assertEq(IERC20(USDC).allowance(address(adapter), POOL), 0);
        assertEq(IERC20(WETH).allowance(address(adapter), address(router)), 0);
    }

    function _fairUsdc(uint256 wethAmount) internal view returns (uint256) {
        IAaveOracle oracle = IAaveOracle(ORACLE);
        return (wethAmount * oracle.getAssetPrice(WETH) * 1e6) / (oracle.getAssetPrice(USDC) * 1e18);
    }

    function test_repay_repaysRealDebtForABorrowerThatIsNotTheCaller() public {
        bytes32 id = _register(_params(adapter.ACTION_REPAY(), USDC, 20e6, 40e6, _hfBelow(1.8e18)));
        uint256 debtBefore = IERC20(V_USDC).balanceOf(principal);
        uint256 hfBefore = _healthFactor(principal);
        assertLt(hfBefore, 1.8e18, "fixture: trigger is true");

        vm.prank(agent);
        uint256 spent = shield.fire(id, 10e6, "");

        assertEq(spent, 10e6);
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDC).balanceOf(principal), 10e6, 2, "debt fell by what was repaid"
        );
        assertGt(_healthFactor(principal), hfBefore);
        _assertNothingLeftBehind();

        assertGe(_healthFactor(principal), 1.8e18, "the repay lifted the health factor past the trigger");
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.TRIGGER_NOT_MET));
        shield.fire(id, 10e6, "");
    }

    function test_repay_boundariesRevertWithTheirReasonCodes() public {
        bytes32 id = _register(_params(adapter.ACTION_REPAY(), USDC, 20e6, 40e6, _hfBelow(10e18)));
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_TX_CAP));
        shield.fire(id, 20e6 + 1, "");
        vm.prank(stranger);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.NOT_AGENT));
        shield.fire(id, 1e6, "");
        vm.prank(agent);
        shield.fire(id, 20e6, "");
        vm.prank(agent);
        shield.fire(id, 20e6, "");
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP));
        shield.fire(id, 1e6, "");

        bytes32 id2 = _register(_params(adapter.ACTION_REPAY(), USDC, 20e6, 40e6, _hfBelow(10e18)));
        vm.prank(enforcer);
        shield.freezeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(_blocked(id2, ISignoShield.MandateReason.AGENT_FROZEN));
        shield.fire(id2, 1e6, "");
        vm.prank(enforcer);
        shield.unfreezeAgent(agent);
        vm.prank(principal);
        shield.revokeMandate(id2);
        vm.prank(agent);
        vm.expectRevert(_blocked(id2, ISignoShield.MandateReason.REVOKED));
        shield.fire(id2, 1e6, "");

        bytes32 id3 = _register(_params(adapter.ACTION_REPAY(), USDC, 20e6, 40e6, _hfBelow(10e18)));
        vm.warp(uint256(validUntil) + 1);
        vm.prank(agent);
        vm.expectRevert(_blocked(id3, ISignoShield.MandateReason.EXPIRED));
        shield.fire(id3, 1e6, "");
        _assertNothingLeftBehind();
    }

    function test_supply_raisesTheOwnersATokenBalance() public {
        vm.prank(principal);
        IERC20(WETH).approve(address(shield), type(uint256).max);
        bytes32 id = _register(_params(adapter.ACTION_SUPPLY(), WETH, 0.01e18, 0.02e18, _noCondition()));
        uint256 aBefore = IERC20(A_WETH).balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 0.01e18, "");
        assertEq(spent, 0.01e18);
        assertApproxEqAbs(IERC20(A_WETH).balanceOf(principal) - aBefore, 0.01e18, 2);
        _assertNothingLeftBehind();
    }

    function test_repayWithCollateral_bringsTheHealthFactorToTarget() public {
        ISignoShield.MandateParams memory p =
            _params(adapter.ACTION_REPAY_WITH_COLLATERAL(), A_WETH, 0.01e18, 0.02e18, _hfBelow(1.8e18));
        p.actionConfig = abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: WETH,
                debtAsset: USDC,
                targetHealthFactor: 1.9e18,
                maxSlippageBps: 100,
                router: address(router),
                spender: address(router)
            })
        );
        bytes32 id = _register(p);
        uint256 slice = 0.008e18;
        uint256 amountIn = slice - 1_000;
        uint256 amountOut = (_fairUsdc(amountIn) * 9_950) / 10_000;
        uint256 debtBefore = IERC20(V_USDC).balanceOf(principal);

        vm.prank(agent);
        uint256 spent = shield.fire(
            id, slice, abi.encodeCall(MockRouter.swap, (WETH, amountIn, USDC, amountOut, address(adapter)))
        );

        assertApproxEqAbs(spent, slice, 2);
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDC).balanceOf(principal), amountOut, 2, "debt fell by the swap output"
        );
        assertGe(_healthFactor(principal), 1.9e18, "health factor at or above target");
        _assertNothingLeftBehind();
    }
}

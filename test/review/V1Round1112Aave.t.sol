// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {R1112AaveFixture} from "./R1112AaveFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {AaveV3AdapterV1} from "contracts/v1/AaveV3AdapterV1.sol";

contract V1Round1112AaveTest is R1112AaveFixture {
    /// Round 13 fix of G11-H1 (was the reviewer's gap test): the target gate reads
    /// the health factor BEFORE the pull, so an owner already over the target is
    /// refused even when the pull alone would take the position under it.
    function test_r13_fixAPositionAlreadyAboveTargetIsRefused() public {
        uint256 beforeHf = _healthFactor(principal);
        uint256 target = beforeHf - 0.05e18;
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.02e18, 0.05e18, "");
        p.actionConfig = _rwcConfig(target);
        bytes32 id = _register(p);
        shield.setFeeRecipient(address(0xFEE));
        uint256 amount = 0.008e18;
        uint256 sold = amount - 1_000;
        uint256 beforeBalance = IERC20(A_XETH).balanceOf(principal);
        uint256 beforeDebt = IERC20(V_USDT0).balanceOf(principal);
        bytes memory route = _swapCalldata(sold, _fairUsdt0(sold) * 9_950 / 10_000, address(adapter));
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
        shield.fire(id, amount, route);
        assertEq(IERC20(A_XETH).balanceOf(principal), beforeBalance, "nothing pulled");
        assertEq(IERC20(V_USDT0).balanceOf(principal), beforeDebt);
        assertEq(IERC20(A_XETH).balanceOf(address(0xFEE)), 0, "no fee for a refused firing");
        assertEq(_healthFactor(principal), beforeHf);
    }

    function test_r1112_prePullTriggerPreventsAboveTargetFiring() public {
        uint256 target = _healthFactor(principal) - 0.05e18;
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.02e18, 0.05e18, _hfBelow(target));
        p.actionConfig = _rwcConfig(target);
        bytes32 id = _register(p);
        uint256 beforeBalance = IERC20(A_XETH).balanceOf(principal);
        bytes memory route = _swapCalldata(0.008e18 - 1_000, 1e6, address(adapter));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0.008e18, route);
        assertEq(IERC20(A_XETH).balanceOf(principal), beforeBalance);
        assertEq(shield.getMandate(id).firings, 0);
    }

    function test_r1112_agentCanRepeatTinyStepsWithoutReachingTarget() public {
        _borrowToNearOne();
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.05e18, 0.2e18, _hfBelow(1.8e18));
        p.actionConfig = _rwcConfig(1.8e18);
        bytes32 id = _register(p);
        shield.setFeeRecipient(address(0xFEE));
        uint256 initial = _healthFactor(principal);
        for (uint256 i; i < 12; i++) {
            uint256 before = _healthFactor(principal);
            uint256 sold = 1e12 - 1_000;
            bytes memory route = _swapCalldata(sold, _fairUsdt0(sold) * 9_950 / 10_000, address(adapter));
            vm.prank(agent);
            shield.fire(id, 1e12, route);
            assertGt(_healthFactor(principal), before);
        }
        assertEq(shield.getMandate(id).firings, 12);
        assertLt(_healthFactor(principal), 1.8e18);
        assertLt(_healthFactor(principal) - initial, 0.001e18);
        assertGt(IERC20(A_XETH).balanceOf(address(0xFEE)), 0);
    }
}

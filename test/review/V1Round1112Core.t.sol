// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {R1112CoreFixture} from "./R1112CoreFixture.sol";
import {MockScaledToken} from "test/v1/mocks/MockScaledToken.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {Vm} from "forge-std/Vm.sol";

contract V1Round1112CoreTest is R1112CoreFixture {
    /// uint256 actually spans the full ray-sized interval, unlike uint64.
    function testFuzz_r1112_fullRayIndexSettlement(uint256 indexSeed, uint96 amountSeed, uint16 spendSeed)
        public
    {
        uint256 index = bound(indexSeed, 1e27, 2e27);
        (MockScaledToken a, bytes32 id) = _scaledMandate(index);
        uint256 amount = bound(uint256(amountSeed), 1e12, 95e18);
        exec.setSpendBps(bound(uint256(spendSeed), 1, 9_999));
        uint256 before = a.balanceOf(principal);
        vm.recordLogs();
        vm.prank(agent);
        uint256 spent = shield.fire(id, amount, "");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,, uint256 booked, uint256 fee) =
            abi.decode(entries[entries.length - 1].data, (bytes32, uint256, uint256, uint256));
        assertEq(booked, spent);
        assertLe(fee, (spent - fee) * 10 / 10_000, "booked fee never exceeds fee owed");
        uint256 paid = a.balanceOf(feeSink);
        assertApproxEqAbs(paid, fee, 2, "recipient receives booked fee within token rounding");
        assertApproxEqAbs(before - a.balanceOf(principal), spent, 8, "actual versus booked outflow");
        assertLe(paid, amount * 10 / 10_000 + 2, "fee cannot exceed reserve plus token rounding");
        assertLe(a.scaledBalanceOf(address(shield)), 1, "at most one scaled residue");
        assertEq(shield.getMandate(id).cumulativeUsed, spent);
        assertLe(spent, amount + amount * 10 / 10_000);
    }

    function test_r1112_settlementAtIndexAndSpendEndpoints() public {
        for (uint256 i; i < 2; i++) {
            for (uint256 j; j < 2; j++) {
                (MockScaledToken a, bytes32 id) = _scaledMandate(i == 0 ? 1e27 : 2e27);
                exec.setSpendBps(j == 0 ? 0 : 10_000);
                uint256 before = a.balanceOf(principal);
                vm.prank(agent);
                uint256 spent = shield.fire(id, 10e18, "");
                assertApproxEqAbs(before - a.balanceOf(principal), spent, 8);
                assertEq(a.balanceOf(address(shield)), 0);
                if (j == 0) assertEq(spent, 0);
            }
        }
    }

    function test_r1112_exactTokenPartialRefundAndFee() public {
        bytes32 id = _register(_params());
        exec.setSpendBps(2_500);
        uint256 before = usdc.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e6, "");
        assertEq(spent, 25e6 + 25_000);
        assertEq(before - usdc.balanceOf(principal), spent);
        assertEq(usdc.balanceOf(feeSink), 25_000);
        assertEq(usdc.balanceOf(address(shield)), 0);
    }

    function test_r1112_oneScaledUnitCanRemainInCore() public {
        (MockScaledToken a, bytes32 id) = _scaledMandate(11e26);
        exec.setSpendBps(5_000);
        vm.prank(agent);
        shield.fire(id, 12_000, "");
        assertEq(a.scaledBalanceOf(address(shield)), 1, "rounding dust remains; not a sweep guarantee");
        assertEq(a.balanceOf(address(shield)), 1);
        assertEq(a.balanceOf(feeSink), 6);
    }

    function test_r1112_outcomeFailureRollsBackRefundAndFee() public {
        IShieldV1.MandateParams memory p = _params();
        // Empty mock action with an owner outcome that is false after the sale.
        p.outcome = _tree(address(usdc), principal, ExprLib.Kind.GT, usdc.balanceOf(principal));
        bytes32 id = _register(p);
        uint256 before = usdc.balanceOf(principal);
        exec.setSpendBps(2_500);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e6, "");
        assertEq(usdc.balanceOf(principal), before);
        assertEq(usdc.balanceOf(feeSink), 0);
        assertEq(usdc.balanceOf(address(shield)), 0);
        assertEq(shield.getMandate(id).cumulativeUsed, 0);
    }
}

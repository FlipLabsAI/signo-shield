// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

contract ConditionModuleTest is Test {
    ConditionModule internal module;
    MockTarget internal target;

    function setUp() public {
        module = new ConditionModule();
        target = new MockTarget();
        target.set(10, 20, 30);
    }

    function _cond(uint8 word, ICondition.Comparator cmp, uint256 threshold)
        internal
        view
        returns (ICondition.Condition memory)
    {
        return ICondition.Condition({
            target: address(target),
            callData: abi.encodeCall(MockTarget.read, ()),
            wordOffset: word,
            comparator: cmp,
            threshold: threshold
        });
    }

    function test_readsThePinnedWord() public view {
        assertTrue(module.isMet(_cond(0, ICondition.Comparator.LessThan, 11)));
        assertFalse(module.isMet(_cond(0, ICondition.Comparator.LessThan, 10)));
        assertTrue(module.isMet(_cond(1, ICondition.Comparator.LessThanOrEqual, 20)));
        assertFalse(module.isMet(_cond(1, ICondition.Comparator.LessThanOrEqual, 19)));
        assertTrue(module.isMet(_cond(2, ICondition.Comparator.GreaterThan, 29)));
        assertFalse(module.isMet(_cond(2, ICondition.Comparator.GreaterThan, 30)));
        assertTrue(module.isMet(_cond(2, ICondition.Comparator.GreaterThanOrEqual, 30)));
        assertFalse(module.isMet(_cond(2, ICondition.Comparator.GreaterThanOrEqual, 31)));
    }

    function test_singleWordReturn() public view {
        ICondition.Condition memory c = ICondition.Condition({
            target: address(target),
            callData: abi.encodeCall(MockTarget.one, ()),
            wordOffset: 0,
            comparator: ICondition.Comparator.GreaterThanOrEqual,
            threshold: 10
        });
        assertTrue(module.isMet(c));
    }

    /// A reading that cannot be taken reverts. It is never "not met".
    function test_revertsWhenTargetReverts() public {
        target.setFail(true);
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ConditionCallFailed.selector, address(target)));
        module.isMet(_cond(0, ICondition.Comparator.LessThan, 11));
    }

    function test_revertsWhenWordIsBeyondReturnData() public {
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ReturnDataTooShort.selector, 96, 3));
        module.isMet(_cond(3, ICondition.Comparator.LessThan, 11));
    }

    function test_revertsOnTargetWithoutCode() public {
        ICondition.Condition memory c = _cond(0, ICondition.Comparator.LessThan, 11);
        c.target = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ConditionCallFailed.selector, address(0xBEEF)));
        module.isMet(c);
    }

    /// `staticcall`: a condition whose target would write is refused by the EVM.
    function test_cannotWrite() public {
        ICondition.Condition memory c = _cond(0, ICondition.Comparator.LessThan, 11);
        c.callData = abi.encodeCall(MockTarget.set, (1, 2, 3));
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ConditionCallFailed.selector, address(target)));
        module.isMet(c);
        (uint256 a,,) = target.read();
        assertEq(a, 10);
    }
}

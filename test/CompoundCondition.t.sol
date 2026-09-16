// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {CompoundCondition} from "contracts/core/CompoundCondition.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

/// "A and B" / "A or B" over plain triggers (Austin 2026-09-16: "I think we
/// will definitely want 'A and B' quite soon"). Two leaves read words 0 and 1
/// of the same mock target, so one `set` moves both.
contract CompoundConditionTest is Test {
    ConditionModule internal leaf;
    CompoundCondition internal compound;
    MockTarget internal target;

    function setUp() public {
        leaf = new ConditionModule();
        compound = new CompoundCondition(leaf);
        target = new MockTarget();
        target.set(10, 20, 30);
    }

    // ------------------------------------------------------------- helpers

    /// word `w` of target.read() < threshold
    function _leaf(uint8 w, uint256 threshold) internal view returns (ICondition.Condition memory) {
        return ICondition.Condition({
            target: address(target),
            callData: abi.encodeCall(MockTarget.read, ()),
            wordOffset: w,
            comparator: ICondition.Comparator.LessThan,
            threshold: threshold,
            evaluator: address(0)
        });
    }

    function _compound(CompoundCondition.Op op, ICondition.Condition[] memory leaves)
        internal
        view
        returns (ICondition.Condition memory)
    {
        return ICondition.Condition({
            target: address(compound),
            callData: abi.encode(op, leaves),
            wordOffset: 0,
            comparator: ICondition.Comparator.LessThan,
            threshold: 0,
            evaluator: address(compound)
        });
    }

    function _two(ICondition.Condition memory a, ICondition.Condition memory b)
        internal
        pure
        returns (ICondition.Condition[] memory leaves)
    {
        leaves = new ICondition.Condition[](2);
        leaves[0] = a;
        leaves[1] = b;
    }

    // --------------------------------------------------------------- truth

    function test_and_isTrueOnlyWhenEveryLeafIs() public view {
        // word0 = 10 < 15 (true), word1 = 20 < 25 (true)
        assertTrue(compound.isMet(_compound(CompoundCondition.Op.And, _two(_leaf(0, 15), _leaf(1, 25)))));
        // word1 = 20 < 15 (false)
        assertFalse(compound.isMet(_compound(CompoundCondition.Op.And, _two(_leaf(0, 15), _leaf(1, 15)))));
    }

    function test_or_isTrueWhenAnyLeafIs() public view {
        assertTrue(compound.isMet(_compound(CompoundCondition.Op.Or, _two(_leaf(0, 5), _leaf(1, 25)))));
        assertFalse(compound.isMet(_compound(CompoundCondition.Op.Or, _two(_leaf(0, 5), _leaf(1, 15)))));
    }

    /// The property that makes this safe to register: a leaf that cannot be
    /// read reverts the whole thing, even under "or" with a true sibling. A
    /// broken feed is never hidden behind a leaf that happened to be true.
    function test_anUnreadableLeafRevertsEvenUnderOr() public {
        ICondition.Condition memory dead = _leaf(0, 15);
        dead.wordOffset = 7; // past the three words read() returns
        ICondition.Condition memory c = _compound(CompoundCondition.Op.Or, _two(_leaf(1, 25), dead));
        assertTrue(leaf.isMet(_leaf(1, 25)), "the sibling alone is true");
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ReturnDataTooShort.selector, 96, 7));
        compound.isMet(c);
    }

    function test_aRevertingTargetRevertsTheCompound() public {
        target.setFail(true);
        ICondition.Condition memory c = _compound(CompoundCondition.Op.And, _two(_leaf(0, 15), _leaf(1, 25)));
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ConditionCallFailed.selector, address(target)));
        compound.isMet(c);
    }

    function test_theSameLeavesTrackTheTarget() public {
        ICondition.Condition memory c = _compound(CompoundCondition.Op.And, _two(_leaf(0, 15), _leaf(1, 25)));
        assertTrue(compound.isMet(c));
        target.set(16, 20, 30);
        assertFalse(compound.isMet(c), "word0 crossed its threshold");
    }

    // -------------------------------------------------------------- shape

    function test_refusesTheWrongTarget() public {
        ICondition.Condition memory c = _compound(CompoundCondition.Op.And, _two(_leaf(0, 15), _leaf(1, 25)));
        c.target = address(target); // a compound pinned at a plain contract
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "target"));
        compound.isMet(c);
    }

    function test_refusesFewerThanTwoOrMoreThanEightLeaves() public {
        ICondition.Condition[] memory one = new ICondition.Condition[](1);
        one[0] = _leaf(0, 15);
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "leaves"));
        compound.isMet(_compound(CompoundCondition.Op.And, one));

        ICondition.Condition[] memory nine = new ICondition.Condition[](9);
        for (uint256 i = 0; i < 9; i++) nine[i] = _leaf(0, 15);
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "leaves"));
        compound.isMet(_compound(CompoundCondition.Op.And, nine));

        ICondition.Condition[] memory eight = new ICondition.Condition[](8);
        for (uint256 i = 0; i < 8; i++) eight[i] = _leaf(0, 15);
        assertTrue(compound.isMet(_compound(CompoundCondition.Op.And, eight)), "eight is the cap, inclusive");
    }

    function test_refusesNestingAndEmptyLeaves() public {
        ICondition.Condition memory nested = _leaf(0, 15);
        nested.evaluator = address(compound);
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "leaf:nested"));
        compound.isMet(_compound(CompoundCondition.Op.And, _two(_leaf(1, 25), nested)));

        ICondition.Condition memory empty = _leaf(0, 15);
        empty.target = address(0);
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "leaf:target"));
        compound.isMet(_compound(CompoundCondition.Op.And, _two(_leaf(1, 25), empty)));
    }

    function test_constructorRequiresALeafModule() public {
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "leafModule"));
        new CompoundCondition(ICondition(makeAddr("nobody")));
    }

    function test_encodeMatchesWhatIsMetDecodes() public view {
        ICondition.Condition[] memory leaves = _two(_leaf(0, 15), _leaf(1, 25));
        bytes memory data = compound.encode(CompoundCondition.Op.And, leaves);
        ICondition.Condition memory c = _compound(CompoundCondition.Op.And, leaves);
        assertEq(keccak256(data), keccak256(c.callData));
    }
}

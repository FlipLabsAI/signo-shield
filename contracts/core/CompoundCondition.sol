// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICondition} from "./interfaces/ICondition.sol";

/// @title CompoundCondition
/// @notice "A and B" / "A or B" over plain triggers, as a listed evaluator.
///         The condition's `callData` carries the operator and the leaves;
///         every leaf is a plain Condition judged by the default module.
///
/// Every leaf is evaluated, every time. There is no short-circuit: an "or"
/// whose first leaf is true still reads the second, so a leaf that cannot be
/// read — a broken feed, a wrong selector — reverts the whole evaluation
/// instead of being hidden behind a true sibling. That keeps the default
/// module's rule intact at this level too: a reading that cannot be taken is
/// never reported as met or as not met. It also means the registration
/// dry-run exercises every leaf, so a mandate with one dead leaf is refused
/// at signing rather than discovered at its first firing.
///
/// Leaves only, one level deep. Nesting would make the cost of a trigger
/// unbounded and its meaning hard to show on a review screen; eight flat
/// leaves cover "health factor below X and price above Y and balance over Z"
/// with room to spare. A leaf naming an evaluator, this contract, the leaf
/// module or an `isMet` call is refused. A leaf is still an arbitrary view
/// read the principal chose (a wrapper contract can hide anything behind a
/// plain selector), so a review screen must show each leaf as the read it is.
contract CompoundCondition is ICondition {
    enum Op {
        And,
        Or
    }

    uint256 public constant MAX_LEAVES = 8;

    /// @notice The plain reader every leaf is judged by.
    ICondition public immutable leafModule;

    error BadCompound(string field);

    constructor(ICondition leafModule_) {
        if (address(leafModule_).code.length == 0) revert BadCompound("leafModule");
        leafModule = leafModule_;
    }

    /// @notice How to build the `callData` for a compound condition.
    function encode(Op op, Condition[] calldata leaves) external pure returns (bytes memory) {
        return abi.encode(op, leaves);
    }

    /// @inheritdoc ICondition
    function isMet(Condition calldata condition) external view returns (bool) {
        // The Shield reads `target != 0` as "there is a trigger"; for a compound
        // the only honest target is this contract. Anything else is a config
        // that pinned the wrong evaluator or the wrong target.
        if (condition.target != address(this)) revert BadCompound("target");
        // The outer word, comparator and threshold mean nothing for a compound.
        // They must be zero, so one trigger has one encoding and a screen or an
        // indexer that shows them cannot show a condition that is not the one
        // judged. The registration dry-run refuses anything else.
        if (
            condition.wordOffset != 0 || condition.comparator != Comparator.LessThan
                || condition.threshold != 0
        ) {
            revert BadCompound("shape");
        }
        (Op op, Condition[] memory leaves) = abi.decode(condition.callData, (Op, Condition[]));
        if (leaves.length < 2 || leaves.length > MAX_LEAVES) revert BadCompound("leaves");

        // Shape first, in one pass, reverting after it: every leaf must name a
        // target and must be a plain leaf, not another evaluator. The error
        // names the first bad field, which is what a registration UI needs.
        string memory bad = _badLeaf(leaves);
        if (bytes(bad).length != 0) revert BadCompound(bad);

        uint256 met = 0;
        for (uint256 i = 0; i < leaves.length; i++) {
            // An external call per leaf is the design, not an accident: at most
            // eight, all to the one immutable module, and a leaf that reverts
            // MUST revert the loop — that is the no-short-circuit guarantee.
            // forge-lint: disable-next-line(calls-loop)
            if (leafModule.isMet(leaves[i])) met++;
        }
        return op == Op.And ? met == leaves.length : met != 0;
    }

    /// @dev The first shape fault among the leaves, or the empty string.
    function _badLeaf(Condition[] memory leaves) internal view returns (string memory) {
        for (uint256 i = 0; i < leaves.length; i++) {
            if (leaves[i].target == address(0)) return "leaf:target";
            if (leaves[i].evaluator != address(0)) return "leaf:nested";
            // A leaf that reads this contract, or calls any evaluator's isMet,
            // is a nested compound spelled as a plain read.
            if (leaves[i].target == address(this) || leaves[i].target == address(leafModule)) {
                return "leaf:nested";
            }
            if (leaves[i].callData.length < 4) return "leaf:callData";
            // casting to bytes4 is safe: the line above guarantees four bytes, and
            // bytes4 of a longer array keeps its first four, the selector.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (bytes4(leaves[i].callData) == ICondition.isMet.selector) return "leaf:nested";
        }
        return "";
    }
}

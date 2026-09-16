// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICondition} from "./interfaces/ICondition.sol";

/// @title ConditionModule
/// @notice The one generic trigger. Reads a pinned view call with `staticcall`,
///         takes one 32-byte word out of the return data, compares it.
///
/// Health factor, oracle price, token balance and vault share price are all
/// this contract with different pins. `staticcall` cannot change state, which
/// is what makes a generic reader safe where a generic writer would not be.
///
/// A reading that cannot be taken REVERTS. It never reports "not met": a
/// failed evaluation reported as a denial would let a broken oracle silently
/// disarm every mandate that reads it, and a failed evaluation reported as
/// "met" would fire mandates on nothing. Reverting is the only honest answer.
contract ConditionModule is ICondition {
    /// @notice The pinned view call reverted or the target has no code.
    error ConditionCallFailed(address target);
    /// @notice The return data does not reach the pinned word.
    error ReturnDataTooShort(uint256 length, uint8 wordOffset);

    /// @inheritdoc ICondition
    function isMet(Condition calldata condition) external view returns (bool) {
        if (condition.target.code.length == 0) revert ConditionCallFailed(condition.target);
        (bool ok, bytes memory ret) = condition.target.staticcall(condition.callData);
        if (!ok) revert ConditionCallFailed(condition.target);
        uint8 offset = condition.wordOffset;
        if (ret.length < (uint256(offset) + 1) * 32) revert ReturnDataTooShort(ret.length, offset);
        uint256 value;
        assembly ("memory-safe") {
            value := mload(add(add(ret, 32), mul(offset, 32)))
        }
        return _compare(value, condition.comparator, condition.threshold);
    }

    function _compare(uint256 value, Comparator comparator, uint256 threshold) internal pure returns (bool) {
        if (comparator == Comparator.LessThan) return value < threshold;
        if (comparator == Comparator.LessThanOrEqual) return value <= threshold;
        if (comparator == Comparator.GreaterThan) return value > threshold;
        return value >= threshold;
    }
}

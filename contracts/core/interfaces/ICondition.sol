// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICondition
/// @notice One generic trigger, not one contract per trigger kind.
///
/// A condition pins a view target, its calldata, the word offset to read out of
/// the return data, a comparator and a threshold. `staticcall` cannot change
/// state, so a fully generic reader is safe here in a way a generic writer
/// would not be. Health factor, oracle price, token balance and vault share
/// price are all the same contract.
///
/// This is the part nobody else ships: all nine ERC-7579 SmartSessions policies
/// inspect the call being made. None of them read protocol state.
///
/// NOT IMPLEMENTED HERE — see ISignoShield.
interface ICondition {
    enum Comparator {
        LessThan,
        LessThanOrEqual,
        GreaterThan,
        GreaterThanOrEqual
    }

    /// @param target      the contract to read
    /// @param callData    the view call to make against it
    /// @param wordOffset  which 32-byte word of the return data carries the value
    /// @param comparator  how the value is compared to `threshold`
    /// @param threshold   the number the value is compared against
    struct Condition {
        address target;
        bytes callData;
        uint8 wordOffset;
        Comparator comparator;
        uint256 threshold;
    }

    /// @notice True when the pinned reading satisfies the comparator.
    /// @dev MUST use `staticcall`. A condition that can write is not a condition.
    function isMet(Condition calldata condition) external view returns (bool);
}

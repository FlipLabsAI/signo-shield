// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEvaluatorV1
/// @notice One stateless contract that judges any bounded expression tree a
///         mandate pins as data. Every call is a view made by the core with the
///         core's stored data and the principal. A read or arithmetic failure
///         reverts; it is never turned into true or false.
interface IEvaluatorV1 {
    enum Phase {
        Trigger, // may use CONST, READ, SIGNED, AMOUNT
        Outcome // may also use BEFORE
    }

    error TreeInvalid(string reason);
    error ReadFailed(uint256 readIndex, bytes reason);
    error ReadTooShort(uint256 readIndex, uint256 length, uint256 needed);
    error ReadStale(uint256 readIndex);
    error ReadNotPositive(uint256 readIndex);
    error SubjectMismatch(uint256 readIndex);
    error ValueOutOfRange(uint256 nodeIndex);

    /// @notice Shape, type and descriptor checks, and one liveness read per Read. Reverts with a named reason.
    ///         `requireListed` is true for a new tree (registration, or a changed tree on amendment): every
    ///         descriptor must be listed. An unchanged tree on amendment passes with delisted descriptors;
    ///         revoked ones always fail.
    function validate(bytes calldata tree, Phase phase, address principal, bool requireListed) external view;

    /// @notice The values every SIGNED node names, indexed by read.
    function capture(bytes calldata tree, address principal)
        external
        view
        returns (int256[] memory signedValues);

    /// @notice The values every BEFORE node names, indexed by read.
    function snapshot(bytes calldata outcome, address principal)
        external
        view
        returns (int256[] memory beforeValues);

    /// @notice The trigger, judged before anything moves.
    function judgeTrigger(
        bytes calldata trigger,
        address principal,
        int256[] calldata signedValues,
        uint256 amount
    ) external view returns (bool);

    /// @notice The outcome, judged on the owner's final state.
    function judgeOutcome(
        bytes calldata outcome,
        address principal,
        int256[] calldata signedValues,
        int256[] calldata beforeValues,
        uint256 amount
    ) external view returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IShieldRegistryV1
/// @notice The listings, the read catalog and the emergency controls the
///         core, the evaluator and the executors consult. Narrowing only:
///         nothing here can widen what an owner signed.
interface IShieldRegistryV1 {
    event AgentFrozen(address indexed agent, address indexed enforcer);
    event AgentUnfrozen(address indexed agent, address indexed enforcer);
    event EnforcerSet(address indexed enforcer, bool enabled);
    event ExecutorListed(address indexed executor, bool listed);
    event EvaluatorListed(address indexed evaluator, bool listed);
    event Halted(address indexed listed, uint64 epoch, address indexed by);
    event UnhaltQueued(address indexed listed, uint64 epoch, address indexed by);
    event UnhaltExecuted(address indexed listed, uint64 epoch, address indexed by);
    event Suspended(address indexed target, uint64 epoch, address indexed by);
    event LiftQueued(address indexed target, uint64 epoch, address indexed by);
    event LiftExecuted(address indexed target, uint64 epoch, address indexed by);
    event Revoked(address indexed target, address indexed by);

    error NotEnforcer();
    error InvalidParams(bytes32 field);
    error AdminCannotBeEnforcer(address account);
    error RestoreNotReady(address target, uint64 epoch);
    error EpochMismatch(address target, uint64 epoch);
    error TargetRevoked(address target);

    /// @notice Halted, suspended or revoked: a listed contract that must not act.
    function stopped(address listed) external view returns (bool);
    function isAgentFrozen(address agent) external view returns (bool);
    function isEnforcer(address account) external view returns (bool);
    function isExecutorListed(address executor) external view returns (bool);
    function isEvaluatorListed(address evaluator) external view returns (bool);
    function isHalted(address listed) external view returns (bool);
    function isSuspended(address target) external view returns (bool);
    function isRevoked(address target) external view returns (bool);
    function isVenueBlocked(address target) external view returns (bool);
}

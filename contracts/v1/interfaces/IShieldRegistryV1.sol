// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IShieldRegistryV1
/// @notice The listings, the read catalog and the emergency controls the
///         core, the evaluator and the executors consult. Narrowing only:
///         nothing here can widen what an owner signed.
interface IShieldRegistryV1 {
    /// @notice An approved claim: the one call a claim mandate may make on a venue, with the
    ///         owner's address written into the `ownerArgs` words at firing. `args` holds every
    ///         static argument word; the owner words are zero in it. Content-addressed like a
    ///         descriptor: nothing can be stored under an id with different contents.
    struct ClaimRule {
        address target; // the venue whose claim function runs (for example a Pendle market)
        bytes4 selector; // the claim function (for example redeemRewards(address))
        uint8 argCount; // static 32-byte argument words after the selector
        uint16 ownerArgs; // bit i set: argument i is the owner (at least one bit, below argCount)
        bytes args; // argCount words; the owner words zero
    }

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
    event PriceRoundSet(address indexed token, bytes32 descriptor, address feed);
    event ClaimRuleListed(bytes32 indexed id, bool listed);
    event ClaimRuleRevoked(bytes32 indexed id, address indexed by);

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
    /// @notice The admin of the registry; the core's admin too (one admin, one enforcer exclusion).
    function owner() external view returns (address);
    /// @notice The fresh price round every mandatory price read of `token` must pass, when one is
    ///         listed (the read catalog's rule: a positive price AND a fresh underlying round where one
    ///         exists). A zero descriptor means positivity only.
    function priceRound(address token) external view returns (bytes32 descriptor, address feed);
    /// @notice The claim rule behind `id`, whether new mandates may sign it, and whether it is revoked
    ///         (a revoked rule stops every live mandate that uses it).
    function claimRuleOf(bytes32 id) external view returns (ClaimRule memory rule, bool listed, bool revoked);
}

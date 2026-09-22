// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IShieldV1
/// @notice The Shield v1 core: mandates, listings, the read catalog, halts,
///         suspensions and revocations, and the firing.
interface IShieldV1 {
    enum FundingMode {
        PULL, // the core pulls `amount` of the asset from the principal to the executor
        NONE // nothing is pulled; amount must be 0 (claims)
    }

    enum MandateReason {
        OK,
        NONEXISTENT,
        AGENT_FROZEN,
        NOT_AGENT,
        EXECUTOR_HALTED,
        EVALUATOR_HALTED,
        NOT_YET_VALID,
        EXPIRED,
        REVOKED,
        ZERO_AMOUNT,
        AMOUNT_NOT_ZERO,
        OVER_TX_CAP,
        OVER_CUMULATIVE_CAP,
        INSUFFICIENT_ALLOWANCE,
        INSUFFICIENT_BALANCE,
        TRIGGER_NOT_MET,
        OUTCOME_FAILED
    }

    struct MandateParams {
        address agent;
        address executor;
        address evaluator;
        address asset;
        uint256 maxTransactionValue;
        uint256 maxCumulativeValue;
        uint48 validFrom;
        uint48 validUntil;
        uint16 maxFeeBps;
        uint8 funding;
        bytes32 action;
        bytes actionConfig;
        bytes trigger;
        bytes outcome;
    }

    struct Mandate {
        address principal;
        address agent;
        address executor;
        address evaluator;
        address asset;
        uint256 maxTransactionValue;
        uint256 maxCumulativeValue;
        uint256 cumulativeUsed;
        uint48 validFrom;
        uint48 validUntil;
        uint48 lastFiredAt;
        uint32 revision;
        uint32 firings;
        uint16 maxFeeBps;
        uint16 feeBps;
        uint8 funding;
        bool revoked;
        bytes32 action;
        bytes actionConfig;
        bytes trigger;
        bytes outcome;
        int256[] triggerSigned;
        int256[] outcomeSigned;
    }

    event MandateRegistered(
        bytes32 indexed mandateId,
        address indexed principal,
        address indexed agent,
        address executor,
        address evaluator
    );
    event MandateAmended(bytes32 indexed mandateId, uint32 revision);
    event MandateRevoked(bytes32 indexed mandateId, address indexed principal);
    event MandateFired(
        bytes32 indexed mandateId,
        address indexed agent,
        address indexed executor,
        bytes32 action,
        uint256 amount,
        uint256 spent,
        uint256 fee
    );
    event AgentFrozen(address indexed agent, address indexed enforcer);
    event AgentUnfrozen(address indexed agent, address indexed enforcer);
    event EnforcerSet(address indexed enforcer, bool enabled);
    event ExecutorListed(address indexed executor, bool listed);
    event EvaluatorListed(address indexed evaluator, bool listed);
    event FeeRecipientSet(address indexed recipient);
    event FeeBpsSet(uint16 feeBps);
    event Halted(address indexed listed, uint64 epoch, address indexed by);
    event UnhaltQueued(address indexed listed, uint64 epoch, address indexed by);
    event UnhaltExecuted(address indexed listed, uint64 epoch, address indexed by);
    event Suspended(address indexed target, uint64 epoch, address indexed by);
    event LiftQueued(address indexed target, uint64 epoch, address indexed by);
    event LiftExecuted(address indexed target, uint64 epoch, address indexed by);
    event Revoked(address indexed target, address indexed by);

    error MandateBlocked(bytes32 mandateId, MandateReason reason);
    error OutcomeRejected(bytes32 mandateId, MandateReason reason, bytes detail);
    error NotPrincipal();
    error NotEnforcer();
    error ExecutorNotListed(address executor);
    error EvaluatorNotListed(address evaluator);
    error ActionNotSupported(address executor, bytes32 action);
    error FeeAboveMax(uint16 feeBps, uint16 maxFeeBps);
    error InvalidParams(string field);
    error FieldImmutable(string field);
    error AdminCannotBeEnforcer(address account);
    error SpendExceedsAmount(uint256 spent, uint256 amount);
    error NothingMayLeave(uint256 left);
    error RestoreNotReady(address target, uint64 epoch);
    error EpochMismatch(address target, uint64 epoch);
    error TargetRevoked(address target);
    error BadSignature();
    error SignatureExpired();

    function registerMandate(MandateParams calldata params) external returns (bytes32 mandateId);
    function amendMandate(bytes32 mandateId, MandateParams calldata params) external;
    function revokeMandate(bytes32 mandateId) external;
    function revokeWithSig(bytes32 mandateId, uint256 deadline, bytes calldata signature) external;
    function fire(bytes32 mandateId, uint256 amount, bytes calldata route) external returns (uint256 spent);
    function canFireBy(bytes32 mandateId, address caller, uint256 amount)
        external
        view
        returns (bool ok, MandateReason reason);
    function getMandate(bytes32 mandateId) external view returns (Mandate memory);
    function isHalted(address listed) external view returns (bool);
    function isSuspended(address target) external view returns (bool);
    function isRevoked(address target) external view returns (bool);
    function isVenueBlocked(address target) external view returns (bool);
}

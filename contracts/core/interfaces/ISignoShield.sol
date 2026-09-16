// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICondition} from "./ICondition.sol";

/// @title ISignoShield
/// @notice The execution surface an owner grants to an agent.
///
/// The design rule this interface encodes: **the contract enforces the BOUND,
/// Signo decides the ACTION.** Anything that is a number goes on chain,
/// because a number is enforceable without understanding anything. Anything
/// that is a judgement stays off chain.
///
/// A mandate is one standing permission: who may fire it (`agent`), for whom
/// (`principal`, always the registering wallet), what it pulls (`asset`), how
/// much per firing and in total, when it is valid, under which on-chain
/// condition, and which pinned execution implementation performs the action.
/// The agent's entire authority is `fire(mandateId, amount, data)`.
///
/// Field names follow ERC-8226 (Regulated Agent Mandate) wherever they mean
/// the same thing: `principal`, `agent`, `asset`, `validFrom`, `validUntil`,
/// `revoked`, `maxTransactionValue`, `maxCumulativeValue`, `cumulativeUsed`.
/// Two of its rules come with the names and are kept here: `cumulativeUsed`
/// never resets when a mandate is extended, and an amendment re-renders the
/// whole permission rather than merging a delta. This contract is
/// interface-aligned with ERC-8226, never conformant: it has no compliance
/// provider, and it carries a trigger and an outcome check, which no standard
/// on that list does.
///
/// Tiers. A mandate pins an execution implementation (`adapter`, `action`).
/// Tier 2 pins a protocol adapter that builds the protocol call itself
/// (`contracts/adapters/`). Tier 1 pins the generic executor
/// (`contracts/executors/`): bounded execution through a disposable clone and
/// a post-condition on the owner's balances, behind the same entry point.
interface ISignoShield {
    /// @notice Why a firing is refused. `canFire` returns the FIRST failing
    ///         check in a fixed order; `fire` reverts with the same code.
    /// @dev Append-only. The numeric order carries no meaning; the check order
    ///      is documented on `canFire`. `POSTCONDITION_FAILED` is execution-time
    ///      only and is never returned by `canFire`.
    enum MandateReason {
        OK,
        NONEXISTENT,
        AGENT_FROZEN,
        NOT_AGENT,
        NOT_YET_VALID,
        EXPIRED,
        REVOKED,
        ZERO_AMOUNT,
        OVER_TX_CAP,
        OVER_CUMULATIVE_CAP,
        TRIGGER_NOT_MET,
        POSTCONDITION_FAILED,
        /// The principal's allowance to the Shield is short of the worst case
        /// (amount plus the fee on all of it). Appended after the ERC-8226-shaped
        /// codes so nothing above renumbers; checked after the caps and before
        /// the trigger.
        INSUFFICIENT_ALLOWANCE,
        /// The principal's balance is short of the same worst case.
        INSUFFICIENT_BALANCE
    }

    /// @notice The stored record. `principal` is `msg.sender` at registration
    ///         and is never a parameter.
    struct Mandate {
        // ERC-8226-aligned fields.
        address principal;
        address agent;
        address asset;
        uint48 validFrom;
        uint48 validUntil;
        bool revoked;
        uint256 maxTransactionValue;
        uint256 maxCumulativeValue;
        uint256 cumulativeUsed;
        // Signo's own fields. `feeBps` is the Shield's fee at the moment of
        // registration, stamped into the record: a mandate's fee never changes
        // for its whole life, whatever the Shield charges new mandates later.
        address adapter;
        bytes32 action;
        uint16 feeBps;
        ICondition.Condition condition;
        bytes actionConfig;
    }

    /// @notice What the principal signs. Everything except `principal`, the
    ///         accounting fields and `feeBps`, which the Shield stamps from its
    ///         current fee so that no registration can undercut it.
    /// @param condition The on-chain trigger. `condition.target == address(0)`
    ///        means no on-chain trigger: the decision to fire is Signo's alone,
    ///        and the bound is everything else in the record.
    /// @param actionConfig Opaque to the core. Validated and interpreted by the
    ///        pinned adapter.
    struct MandateParams {
        address agent;
        address adapter;
        bytes32 action;
        address asset;
        uint256 maxTransactionValue;
        uint256 maxCumulativeValue;
        uint48 validFrom;
        uint48 validUntil;
        ICondition.Condition condition;
        bytes actionConfig;
    }

    /// @notice A mandate was registered or amended. Carries the WHOLE resulting
    ///         record, never a delta, so a user and an indexer read the same
    ///         thing. Amendment emits this same shape.
    event MandateRendered(
        address indexed principal, address indexed agent, bytes32 indexed mandateId, Mandate mandate
    );
    /// @notice The principal revoked a mandate. Irreversible.
    event MandateRevoked(bytes32 indexed mandateId, address indexed principal);
    /// @notice One firing. `amount` is what the agent asked for, `spent` what
    ///         left the principal's wallet for good (fee included), `fee` the
    ///         part that went to the fee recipient.
    event MandateFired(
        bytes32 indexed mandateId,
        address indexed agent,
        address indexed adapter,
        bytes32 action,
        uint256 amount,
        uint256 spent,
        uint256 fee
    );
    event AgentFrozen(address indexed agent, address indexed enforcer);
    event AgentUnfrozen(address indexed agent, address indexed enforcer);
    event EnforcerSet(address indexed enforcer, bool enabled);
    event AdapterListed(address indexed adapter, bool listed);
    event FeeRecipientSet(address indexed recipient);
    /// @notice The fee new mandates will carry. Reaches no live mandate.
    event FeeBpsSet(uint16 feeBps);

    /// @notice The firing was refused; `reason` is what `canFire` would return.
    error MandateBlocked(bytes32 mandateId, MandateReason reason);
    /// @notice The pinned adapter did not produce the required outcome. Every
    ///         adapter-side revert surfaces as this, with the adapter's own
    ///         revert data attached, so a relayer reads one typed code and
    ///         still sees the exact cause.
    error OutcomeRejected(bytes32 mandateId, MandateReason reason, bytes adapterError);
    /// @notice Only the mandate's principal may amend or revoke it.
    error NotPrincipal();
    /// @notice Only an enforcer may freeze or unfreeze an agent.
    error NotEnforcer();
    /// @notice The adapter is not on the allowlist for NEW registrations.
    error AdapterNotListed(address adapter);
    /// @notice The adapter does not implement the pinned action.
    error ActionNotSupported(address adapter, bytes32 action);
    /// @notice A parameter failed validation; `field` names it.
    error InvalidParams(string field);
    /// @notice An amendment tried to change a field that can never change.
    error FieldImmutable(string field);
    /// @notice The admin role and the enforcer role may never coincide.
    error AdminCannotBeEnforcer(address account);
    /// @notice The adapter reported consuming more than it was given.
    error SpendExceedsAmount(uint256 spent, uint256 amount);

    /// @notice Register a mandate. `msg.sender` becomes the principal.
    function registerMandate(MandateParams calldata params) external returns (bytes32 mandateId);

    /// @notice Amend a mandate. Principal only. Cannot change `agent`,
    ///         `adapter`, `action`, `asset` or `feeBps`; cannot set
    ///         `maxCumulativeValue` below `cumulativeUsed`. Re-renders and
    ///         emits the whole record.
    function amendMandate(bytes32 mandateId, MandateParams calldata params) external;

    /// @notice Revoke a mandate. Principal only, immediate, irreversible. Works
    ///         whether or not Signo is running.
    function revokeMandate(bytes32 mandateId) external;

    /// @notice Fire a mandate. Agent only. Runs every check in `canFire`'s
    ///         order, reserves `amount` plus the worst-case fee against the
    ///         budget, pulls `amount` from the principal, hands it to the
    ///         pinned adapter, takes the fee on what the adapter actually
    ///         spent, then reconciles the budget to spend plus fee.
    /// @param data Per-firing input for the adapter (for example aggregator
    ///        calldata). Empty for most actions.
    /// @return spent What left the principal's wallet for good, fee included.
    function fire(bytes32 mandateId, uint256 amount, bytes calldata data) external returns (uint256 spent);

    /// @notice Would `fire(mandateId, amount)` by the mandate's agent pass?
    ///         Returns the first failing check, in this fixed order:
    ///         NONEXISTENT, AGENT_FROZEN, NOT_AGENT, NOT_YET_VALID, EXPIRED,
    ///         REVOKED, ZERO_AMOUNT, OVER_TX_CAP, OVER_CUMULATIVE_CAP,
    ///         TRIGGER_NOT_MET. Assumes the mandate's agent is the caller, so
    ///         it never answers NOT_AGENT; `canFireBy` checks a given caller.
    ///         A trigger that cannot be evaluated reverts rather than
    ///         reporting false.
    function canFire(bytes32 mandateId, uint256 amount) external view returns (bool ok, MandateReason reason);

    /// @notice `canFire` for a specific caller: what `fire` would answer if
    ///         `caller` sent it, NOT_AGENT included.
    function canFireBy(bytes32 mandateId, address caller, uint256 amount)
        external
        view
        returns (bool ok, MandateReason reason);

    function getMandate(bytes32 mandateId) external view returns (Mandate memory);

    /// @notice Halt every mandate `agent` holds, for every principal, in one
    ///         transaction. Enforcer only. Reversible with `unfreezeAgent`.
    ///         Cannot revoke, cannot move funds, cannot widen anything.
    function freezeAgent(address agent) external;
    function unfreezeAgent(address agent) external;
    function isAgentFrozen(address agent) external view returns (bool);
    function isEnforcer(address account) external view returns (bool);
    function isAdapterListed(address adapter) external view returns (bool);
    function conditionModule() external view returns (ICondition);
    function feeRecipient() external view returns (address);
    /// @notice The fee, in basis points of what each firing actually spends,
    ///         stamped into every NEW mandate. Taken on top of the amount and
    ///         counted against the lifetime cap.
    function feeBps() external view returns (uint16);
}

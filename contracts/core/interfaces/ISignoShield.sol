// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISignoShield
/// @notice The execution surface an owner grants to an agent.
///
/// The design rule this interface exists to encode: **the contract enforces the
/// BOUND, Signo decides the ACTION.** Anything that is a number goes on chain,
/// because a number is enforceable without understanding anything. Anything
/// that is a judgement stays off chain.
///
/// Tier 1, bounded execution, is the default and needs zero new Solidity per
/// protocol. Three pieces, none of which parse calldata:
///   1. the agent holds no allowance; the Shield does, and pulls at most
///      `amount` per firing;
///   2. the call runs from a fresh disposable minimal-proxy clone that holds no
///      allowance, so no standing approval survives the transaction;
///   3. a POST-CONDITION on the owner's balances. The owner pins input token,
///      output token, direction and a minimum rate at registration; the agent
///      supplies only a number, a target and calldata; the contract computes
///      the bound itself.
///
/// Why this is not a calldata filter: a filter parses the call and is fooled by
/// batching and delegatecall. A post-condition measures the owner's balances at
/// the end, so there is no parser to fool. Worst-case loss is tolerance times
/// budget, not a full per-action cap.
///
/// Tier 2, a pinned adapter, is the exception. It is reserved for the demo
/// mandate and for obligation-shaped grants where a balance check cannot see
/// the harm: credit delegation and operator bits.
///
/// NOT IMPLEMENTED HERE. FLIP-190 is the repository scaffold; the contracts
/// land in the tickets it blocks. This interface is the agreed shape they
/// build against, not a suggestion.
interface ISignoShield {
    /// @notice Raised by every entry point in the scaffold build.
    /// @dev Removed by the first implementation ticket. Present so that a
    ///      clean clone compiles, deploys and tests without the scaffold
    ///      pretending to enforce anything.
    error NotImplemented();

    /// @notice A mandate was registered, amended or widened.
    /// @dev Every amendment re-renders the WHOLE resulting permission, never
    ///      the delta, so an indexer and a user read the same thing. Widening
    ///      emits this same shape. `agent` can never change under amendment.
    event MandateRendered(address indexed owner, address indexed agent, bytes32 indexed mandateId);

    /// @notice One firing of a mandate by its agent.
    event MandateFired(bytes32 indexed mandateId, address indexed agent, address indexed target);

    /// @notice Register a mandate. Owner-signed.
    function registerMandate(bytes calldata mandate) external returns (bytes32 mandateId);

    /// @notice Amend a mandate: raise a cap, extend expiry, change the trigger,
    ///         add a Tier 1 action. Owner-signed, one transaction.
    /// @dev Adding a new INPUT TOKEN also needs an ERC-20 approve, so it is one
    ///      signature in an ERC-5792 batching wallet and two elsewhere.
    function amendMandate(bytes32 mandateId, bytes calldata mandate) external;

    /// @notice Revoke a mandate. Owner-signed, immediate.
    function revokeMandate(bytes32 mandateId) external;

    /// @notice Fire a mandate. Agent-signed. The Shield pulls at most the
    ///         mandate's per-firing amount, runs `data` against `target` from a
    ///         disposable clone, then enforces the post-condition.
    function fire(bytes32 mandateId, address target, uint256 amount, bytes calldata data) external;
}

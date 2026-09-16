// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IShieldAdapter
/// @notice A Tier 2 execution implementation: one contract per protocol, one
///         entry point per action, called only by the Shield.
///
/// The mandate pins the PAIR (adapter, action). The Shield never lets an agent
/// choose a target, so an adapter's only caller is the Shield and its only
/// inputs are the mandate context, the amount the Shield already transferred
/// to it, and the per-firing `data` the agent supplied. What `data` may carry
/// is the adapter's decision and is documented per action; for most actions it
/// is empty.
///
/// Contract with the core, in order:
///   1. `validateConfig` is called at registration and amendment and MUST
///      revert unless (action, asset, actionConfig) is a pinning this adapter
///      can honour. It is the adapter's chance to refuse a mandate it could
///      not enforce later.
///   2. On a firing the Shield transfers `amount` of `ctx.asset` to the
///      adapter and then calls `execute`. The adapter performs exactly the
///      pinned action for `ctx.principal`, checks its outcome, returns
///      whatever it did not consume to the principal in the same transaction,
///      and reports the amount consumed. It MUST revert on a failed outcome;
///      a caught failure converted into a success is the one bug this design
///      cannot survive.
///   3. No standing authority may survive `execute`: every ERC-20 approval the
///      adapter grants is reduced to zero before it returns.
interface IShieldAdapter {
    /// @notice What the Shield tells the adapter about the mandate being fired.
    struct Context {
        bytes32 mandateId;
        address principal;
        address agent;
        bytes32 action;
        address asset;
        bytes actionConfig;
    }

    /// @notice True when this adapter implements `action`.
    function supportsAction(bytes32 action) external view returns (bool);

    /// @notice Reverts unless (action, asset, actionConfig) can be enforced by
    ///         this adapter. Called by the Shield at registration and amendment.
    function validateConfig(bytes32 action, address asset, bytes calldata actionConfig) external view;

    /// @notice Perform the pinned action. Only the Shield may call it, and only
    ///         after transferring `amount` of `ctx.asset` to this adapter.
    /// @return spent The amount of `ctx.asset` consumed, at most `amount`. The
    ///         difference is already back with `ctx.principal`.
    function execute(Context calldata ctx, uint256 amount, bytes calldata data)
        external
        returns (uint256 spent);
}

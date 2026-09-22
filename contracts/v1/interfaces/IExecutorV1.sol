// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExecutorV1
/// @notice What fills a mandate's executor slot: the generic executor, or a
///         protocol adapter. The core hands it the pulled amount (funding
///         PULL) or nothing (funding NONE) and the agent's route bytes, and
///         reads back what it spent. Every semantics has mandatory checks the
///         executor runs itself; the owner's outcome tree is judged by the
///         core afterwards, in addition.
/// @dev Semantics values. Reserved upward; an unknown value fails closed in the core.
library SemanticsV1 {
    uint8 internal constant UNSUPPORTED = 0;
    uint8 internal constant TRANSFORM = 1;
    uint8 internal constant TRANSFER = 2;
    uint8 internal constant REDEEM = 3;
    uint8 internal constant REPAY = 4;
    uint8 internal constant CLAIM_COLLECT = 5;
    uint8 internal constant CLAIM_COMPOSE = 6;
}

interface IExecutorV1 {
    struct Context {
        bytes32 mandateId;
        address principal;
        address agent;
        address asset;
        uint8 funding;
        bytes32 action;
        bytes actionConfig;
        uint32 revision;
    }

    /// @notice The semantics value for `action`, or SEM_UNSUPPORTED.
    function semanticsOf(bytes32 action) external view returns (uint8);

    /// @notice Reverts unless `actionConfig` is a complete, self-consistent configuration for `action` on `asset`.
    function validateConfig(bytes32 action, address asset, bytes calldata actionConfig) external view;

    /// @notice Run the action. For funding PULL the core has already transferred `amount` of `ctx.asset` here.
    ///         Returns what was spent of the asset; must be 0 for funding NONE.
    function execute(Context calldata ctx, uint256 amount, bytes calldata route) external returns (uint256 used);
}

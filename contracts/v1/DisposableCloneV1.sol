// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExecutorV1} from "./interfaces/IExecutorV1.sol";

/// @title DisposableCloneV1
/// @notice The sandbox one generic firing runs in. The executor deploys a
///         minimal proxy of this template per firing, funds it, drives it call
///         by call (approve, call, clear), reads its balances between calls
///         where a semantics needs that, then tells it to sweep every token in
///         the mandate's sweep set to the owner. A clone runs once; every
///         address it touches was checked by the executor against the
///         mandate's signed venues and the core's suspension and revocation
///         lists before the call.
contract DisposableCloneV1 {
    using SafeERC20 for IERC20;

    address public immutable executor;
    bool private _started;
    bool private _finished;

    error NotExecutor();
    error AlreadyUsed();
    error ApprovalExceedsBalance(uint256 asked, uint256 held);
    error NotEmpty(address token);
    error CallFailed(bytes reason);

    constructor(address executor_) {
        if (executor_ == address(0)) revert NotExecutor();
        executor = executor_;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    /// @notice One call: approve `spender` for `approveAmount` of `approveToken` if asked,
    ///         call `target` with `data`, clear the approval.
    function step(IExecutorV1.Call calldata c) external onlyExecutor {
        if (_finished) revert AlreadyUsed();
        _started = true;
        if (c.approveAmount != 0) {
            // Exact and bounded: never more than the sandbox holds, so an
            // approval can only ever cover what this firing brought in.
            uint256 held = IERC20(c.approveToken).balanceOf(address(this));
            if (c.approveAmount > held) revert ApprovalExceedsBalance(c.approveAmount, held);
            IERC20(c.approveToken).forceApprove(c.spender, c.approveAmount);
        }
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok, bytes memory reason) = c.target.call(c.data);
        if (!ok) revert CallFailed(reason);
        if (c.approveAmount != 0 && IERC20(c.approveToken).allowance(address(this), c.spender) != 0) {
            IERC20(c.approveToken).forceApprove(c.spender, 0);
        }
    }

    /// @notice Sweep every token in `tokens` to `owner` and retire the clone.
    function finish(address[] calldata tokens, address owner) external onlyExecutor {
        if (_finished) revert AlreadyUsed();
        _finished = true;
        for (uint256 i = 0; i < tokens.length; i++) {
            // forge-lint: disable-next-line(calls-loop)
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            // forge-lint: disable-next-line(calls-loop)
            if (held != 0) IERC20(tokens[i]).safeTransfer(owner, held);
            // Proven empty, not assumed from a successful transfer.
            // forge-lint: disable-next-line(calls-loop)
            if (IERC20(tokens[i]).balanceOf(address(this)) > 0) revert NotEmpty(tokens[i]);
        }
    }
}

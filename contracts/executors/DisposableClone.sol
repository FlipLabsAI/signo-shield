// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DisposableClone
/// @notice The sandbox one generic firing runs in (FLIP-238). The executor
///         deploys a minimal proxy of this template per firing, funds it with
///         exactly the amount the Shield pulled, lets it make ONE call to the
///         target pinned in the mandate, and never uses it again. Whatever
///         the call leaves behind is swept to the owner in the same
///         transaction, and the approval the clone granted is cleared, so an
///         approval the calldata tricks the clone into keeping is worthless:
///         the clone never holds anything again.
///
///         `executor` is an immutable in the template's code, which every
///         clone shares, so a clone needs no initialisation and nobody can
///         claim one before its executor does.
contract DisposableClone {
    using SafeERC20 for IERC20;

    address public immutable executor;

    error NotExecutor();
    error AlreadyUsed();
    error CallFailed(bytes reason);

    constructor(address executor_) {
        if (executor_ == address(0)) revert NotExecutor();
        executor = executor_;
    }

    /// @dev A clone runs at most once; the flag lives in the clone's own storage.
    bool private _used;

    /// @notice Approve `spender` for `amount` of `tokenIn`, call `target`
    ///         with `data`, clear the approval, and send every `tokenIn` and
    ///         `tokenOut` this clone holds to `owner`. Every address here was
    ///         validated by the executor at registration (the surface) or by
    ///         the Shield (the principal); the clone trusts its executor.
    // forge-lint: disable-next-item(missing-zero-check)
    function run(
        address target,
        address spender,
        address tokenIn,
        uint256 amount,
        bytes calldata data,
        address tokenOut,
        address owner
    ) external {
        if (msg.sender != executor) revert NotExecutor();
        if (_used) revert AlreadyUsed();
        _used = true;
        if (amount != 0) IERC20(tokenIn).forceApprove(spender, amount);
        // The pinned target, the agent's calldata: the call is the whole point
        // of the clone, and the executor measures the owner afterwards.
        // forge-lint: disable-next-line(unchecked-call)
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) revert CallFailed(reason);
        if (IERC20(tokenIn).allowance(address(this), spender) != 0) IERC20(tokenIn).forceApprove(spender, 0);
        _sweep(tokenIn, owner);
        if (tokenOut != tokenIn) _sweep(tokenOut, owner);
    }

    function _sweep(address token, address to) internal {
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held != 0) IERC20(token).safeTransfer(to, held);
    }
}

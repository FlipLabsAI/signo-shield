// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Stands in for a DEX aggregator router in the fork tests: pulls `amountIn`
/// of `tokenIn` from the caller and pays `amountOut` of `tokenOut` from its
/// own balance to `to`. The caller (the "agent" building calldata) chooses the
/// numbers, which is exactly the trust boundary the adapter has to hold.
contract MockRouter {
    using SafeERC20 for IERC20;

    bool public shouldRevert;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address to)
        external
    {
        if (shouldRevert) revert("router: no route");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}

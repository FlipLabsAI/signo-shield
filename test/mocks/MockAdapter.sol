// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";

/// A configurable adapter for the core tests. It consumes `spendBps` of what
/// it is given (sent to a sink), returns the rest to the principal, and can be
/// told to misbehave in every way the core must survive.
contract MockAdapter is IShieldAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant ACTION = keccak256("mock.spend");
    bytes32 public constant ACTION_OTHER = keccak256("mock.other");
    address public constant SINK = address(0xdead);

    address public immutable shield;
    uint256 public spendBps = 10_000;
    bool public shouldRevert;
    bool public reenter;
    bool public overReport;
    bool public rejectConfig;

    uint256 public calls;
    bytes32 public lastMandateId;
    address public lastPrincipal;
    address public lastAgent;
    bytes32 public lastAction;
    address public lastAsset;
    bytes public lastConfig;
    uint256 public lastAmount;
    bytes public lastData;

    constructor(address shield_) {
        shield = shield_;
    }

    function setSpendBps(uint256 bps) external {
        spendBps = bps;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setReenter(bool v) external {
        reenter = v;
    }

    function setOverReport(bool v) external {
        overReport = v;
    }

    function setRejectConfig(bool v) external {
        rejectConfig = v;
    }

    function supportsAction(bytes32 action) external pure returns (bool) {
        return action == ACTION || action == ACTION_OTHER;
    }

    function validateConfig(bytes32, address, bytes calldata actionConfig) external view {
        if (rejectConfig || keccak256(actionConfig) == keccak256("bad")) revert("mock: bad config");
    }

    function execute(Context calldata ctx, uint256 amount, bytes calldata data) external returns (uint256) {
        require(msg.sender == shield, "mock: not shield");
        calls++;
        lastMandateId = ctx.mandateId;
        lastPrincipal = ctx.principal;
        lastAgent = ctx.agent;
        lastAction = ctx.action;
        lastAsset = ctx.asset;
        lastConfig = ctx.actionConfig;
        lastAmount = amount;
        lastData = data;
        if (shouldRevert) revert("mock: outcome failed");
        if (reenter) ISignoShield(shield).fire(ctx.mandateId, 1, "");
        uint256 spend = (amount * spendBps) / 10_000;
        if (amount - spend != 0) IERC20(ctx.asset).safeTransfer(ctx.principal, amount - spend);
        if (spend != 0) IERC20(ctx.asset).safeTransfer(SINK, spend);
        return overReport ? amount + 1 : spend;
    }
}

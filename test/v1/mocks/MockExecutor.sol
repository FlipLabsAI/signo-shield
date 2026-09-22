// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IExecutorV1, SemanticsV1} from "contracts/v1/interfaces/IExecutorV1.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A configurable executor: spends `spendBps` of what it received (the
///      rest goes back to the principal), reports `reportOverride` if set,
///      can pull `extraPull` from the principal through a prior approval (to
///      model excess outflow), and can be told to revert.
contract MockExecutor is IExecutorV1 {
    address public immutable shield;
    uint256 public spendBps = 10_000; // spend everything by default
    uint256 public reportOverride; // 0 = report what was spent
    bool public useOverride;
    uint256 public extraPull;
    bool public shouldRevert;
    Context public lastCtx;
    bytes public lastRoute;

    constructor(address shield_) {
        shield = shield_;
    }

    function setSpendBps(uint256 v) external {
        spendBps = v;
    }

    function setReport(bool use, uint256 v) external {
        useOverride = use;
        reportOverride = v;
    }

    function setExtraPull(uint256 v) external {
        extraPull = v;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function semanticsOf(bytes32 action) external pure returns (uint8) {
        if (action == keccak256("mock.transform")) return SemanticsV1.TRANSFORM;
        if (action == keccak256("mock.claim")) return SemanticsV1.CLAIM_COLLECT;
        return SemanticsV1.UNSUPPORTED;
    }

    function validateConfig(bytes32, address, bytes calldata cfg) external pure {
        if (cfg.length == 1 && cfg[0] == 0xff) revert("bad config");
    }

    function execute(Context calldata ctx, uint256 amount, bytes calldata route)
        external
        returns (uint256 used)
    {
        require(msg.sender == shield, "not shield");
        if (shouldRevert) revert("executor says no");
        lastCtx = ctx;
        lastRoute = route;
        IERC20 asset = IERC20(ctx.asset);
        uint256 spend = amount * spendBps / 10_000;
        if (amount > spend) asset.transfer(ctx.principal, amount - spend); // unspent goes back
        // "spent" tokens are burned to a sink so they leave the system
        if (spend != 0) asset.transfer(address(0xdead), spend);
        if (extraPull != 0) asset.transferFrom(ctx.principal, address(0xdead), extraPull);
        used = useOverride ? reportOverride : spend;
    }
}

/// @dev Minimal ERC-1271 wallet that accepts a fixed signer's signatures.
contract MockWallet1271 {
    address public immutable signer;

    constructor(address s) {
        signer = s;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s_) = abi.decode(sig, (uint8, bytes32, bytes32));
        if (ecrecover(hash, v, r, s_) == signer) return 0x1626ba7e;
        return 0xffffffff;
    }
}

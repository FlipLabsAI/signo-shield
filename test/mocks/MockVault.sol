// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// The parts of ERC-4626 the executor relies on, with two knobs a real vault
/// has and a test needs: the share price moves when underlying is donated
/// (`totalAssets` is the balance held), and an optional deposit fee, which the
/// standard allows `previewDeposit`/`deposit` to include and `convertToShares`
/// to exclude.
contract MockVault is MockERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    uint256 public feeBps;

    constructor(IERC20 underlying_) MockERC20("Vault", "vSHARE", 18) {
        underlying = underlying_;
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    /// Rounds down, excludes fees (EIP-4626).
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 held = totalAssets();
        return supply == 0 || held == 0 ? assets : assets * supply / held;
    }

    /// May include fees (EIP-4626); this vault's fee comes off the shares.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 gross = convertToShares(assets);
        return gross - gross * feeBps / 10_000;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets);
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }
}

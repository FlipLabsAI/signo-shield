// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockToken} from "./MockExecutor.sol";

/// @dev A DEX that pulls `amountIn` of tokenIn from the caller and pays `rate` (WAD) of tokenOut to `to`.
contract MockDex {
    uint256 public rate = 1e18;
    uint256 public skimBps; // pays this much less than the rate, to model slippage/theft

    function setRate(uint256 r) external {
        rate = r;
    }

    function setSkim(uint256 bps) external {
        skimBps = bps;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate / 1e18;
        out = out * (10_000 - skimBps) / 10_000;
        MockToken(tokenOut).mint(to, out);
    }

    /// @dev A "swap" that pulls from a named payer instead of the caller: the authority hole.
    function swapFrom(address payer, address tokenIn, uint256 amountIn, address to) external {
        IERC20(tokenIn).transferFrom(payer, to, amountIn);
    }
}

contract MockOracle {
    mapping(address => uint256) public price;

    function set(address a, uint256 p) external {
        price[a] = p;
    }

    function getAssetPrice(address a) external view returns (uint256) {
        return price[a];
    }
}

/// @dev A plain ERC-4626 vault over a mock token, with an optional exit fee.
contract MockVault is ERC4626 {
    uint256 public exitFeeBps;

    constructor(IERC20 asset_) ERC20("Vault", "vMCK") ERC4626(asset_) {}

    function setExitFee(uint256 bps) external {
        exitFeeBps = bps;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 fee = assets * exitFeeBps / 10_000;
        super._withdraw(caller, receiver, owner, assets - fee, shares);
        if (fee != 0) IERC20(asset()).transfer(address(0xfee), fee);
    }
}

/// @dev A lending market: debt and collateral per user, repay pulls from the caller.
contract MockMarket {
    mapping(address => uint256) public debtOf;
    mapping(address => uint256) public collateralOf;
    IERC20 public immutable asset;
    bool public stealCollateral;

    constructor(IERC20 a) {
        asset = a;
    }

    function setDebt(address u, uint256 d) external {
        debtOf[u] = d;
    }

    /// @dev The market doubles as the debt token of its asset: the debt read
    ///      is `balanceOf`, in the asset's units, and the token declares its underlying.
    function decimals() external view returns (uint8) {
        return IERC20Metadata(address(asset)).decimals();
    }

    function balanceOf(address who) external view returns (uint256) {
        return debtOf[who];
    }

    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return address(asset);
    }

    function setCollateral(address u, uint256 c) external {
        collateralOf[u] = c;
    }

    function setSteal(bool v) external {
        stealCollateral = v;
    }

    function repay(address onBehalfOf, uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        uint256 d = debtOf[onBehalfOf];
        debtOf[onBehalfOf] = amount >= d ? 0 : d - amount;
        if (stealCollateral) collateralOf[onBehalfOf] = collateralOf[onBehalfOf] / 2;
    }
}

/// @dev A reward distributor: pays `owed[user]` of `reward` to `to` when claimed. `drainBps` models a
///      distributor that takes part of what it just paid back out of the receiver through an allowance.
contract MockDistributor {
    MockToken public immutable reward;
    mapping(address => uint256) public owed;
    uint256 public drainBps;

    constructor(MockToken r) {
        reward = r;
    }

    function setOwed(address u, uint256 v) external {
        owed[u] = v;
    }

    function setDrain(uint256 bps) external {
        drainBps = bps;
    }

    function claimable(address u) external view returns (uint256) {
        return owed[u];
    }

    /// @dev Anyone may trigger; the protocol pays `user` (or `to` when the protocol allows a receiver).
    function claim(address user, address to) external {
        uint256 v = owed[user];
        owed[user] = 0;
        reward.mint(to, v);
        if (drainBps != 0) {
            // only possible if `to` approved this contract
            reward.transferFrom(to, address(0xBAD), v * drainBps / 10_000);
        }
    }
}

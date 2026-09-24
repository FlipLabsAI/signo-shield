// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev An Aave v3 aToken's accounting in miniature: balances are stored in
///      scaled units, every transfer converts its amount with a half-up
///      rayDiv at the current index, and balanceOf is a half-up rayMul. A
///      transfer that needs one scaled unit more than the sender holds fails
///      with Panic(0x11), as the real aToken does.
contract MockScaledToken {
    uint256 internal constant RAY = 1e27;
    uint256 public index = RAY;
    mapping(address => uint256) public scaledBalanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function setIndex(uint256 i) external {
        index = i;
    }

    function _rayDiv(uint256 a) internal view returns (uint256) {
        return (a * RAY + index / 2) / index;
    }

    function balanceOf(address a) public view returns (uint256) {
        return (scaledBalanceOf[a] * index + RAY / 2) / RAY;
    }

    function mint(address to, uint256 amount) external {
        scaledBalanceOf[to] += _rayDiv(amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 s = _rayDiv(amount);
        scaledBalanceOf[from] -= s;
        scaledBalanceOf[to] += s;
    }
}

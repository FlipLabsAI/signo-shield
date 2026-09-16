// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// A view target for condition tests: three words of return data, settable,
/// and a switch that makes the read revert.
contract MockTarget {
    uint256 public a;
    uint256 public b;
    uint256 public c;
    bool public fail;

    function set(uint256 a_, uint256 b_, uint256 c_) external {
        a = a_;
        b = b_;
        c = c_;
    }

    function setFail(bool v) external {
        fail = v;
    }

    function read() external view returns (uint256, uint256, uint256) {
        if (fail) revert("target: down");
        return (a, b, c);
    }

    function one() external view returns (uint256) {
        if (fail) revert("target: down");
        return a;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";

/// Scaffold tests (FLIP-190).
///
/// These assert the one thing that is true today: the toolchain builds, the
/// contract deploys, and every entry point REFUSES rather than silently doing
/// nothing. A scaffold that returned success from `fire` would be the worst
/// possible placeholder, because an integrator would read it as working.
///
/// The enforcement tests arrive with the enforcement, in the tickets this one
/// blocks.
contract SignoShieldScaffoldTest is Test {
    SignoShield internal shield;

    function setUp() public {
        shield = new SignoShield();
    }

    function test_deploys() public view {
        assertEq(shield.VERSION(), "0.0.0-scaffold");
    }

    function test_registerMandate_refuses() public {
        vm.expectRevert(ISignoShield.NotImplemented.selector);
        shield.registerMandate("");
    }

    function test_amendMandate_refuses() public {
        vm.expectRevert(ISignoShield.NotImplemented.selector);
        shield.amendMandate(bytes32(0), "");
    }

    function test_revokeMandate_refuses() public {
        vm.expectRevert(ISignoShield.NotImplemented.selector);
        shield.revokeMandate(bytes32(0));
    }

    /// A firing must never succeed in the scaffold, whatever it is handed.
    function testFuzz_fire_refuses(bytes32 mandateId, address target, uint256 amount, bytes calldata data)
        public
    {
        vm.expectRevert(ISignoShield.NotImplemented.selector);
        shield.fire(mandateId, target, amount, data);
    }
}

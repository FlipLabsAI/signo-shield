// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {CompoundCondition} from "contracts/core/CompoundCondition.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {Deploy} from "script/Deploy.s.sol";

/// The deployment script, end to end on an X Layer fork: what it leaves
/// behind, and that the hand-off works the way the runbook says.
contract DeployForkTest is Test {
    address internal owner = makeAddr("shield-owner");
    address internal treasury = makeAddr("treasury");
    address internal enforcer = makeAddr("enforcer");

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), 70_752_723);
    }

    function test_deploy_wiresEverythingAndHandsOff() public {
        (SignoShield shield, ConditionModule conditions, AaveV3Adapter aave, CompoundCondition compound) =
            new Deploy().deployWith(owner, treasury, enforcer, 10);
        assertTrue(shield.isEvaluatorListed(address(compound)), "the compound evaluator is listed with the set");
        assertEq(address(compound.leafModule()), address(conditions));
        (, address deployer,) = vm.readCallers();

        assertEq(address(shield.conditionModule()), address(conditions));
        assertEq(
            address(aave.pool()), 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116, "the X Layer pool, by chain id"
        );
        assertEq(aave.shield(), address(shield));
        assertTrue(shield.isAdapterListed(address(aave)), "adapter listed");
        assertEq(shield.feeBps(), 10);
        assertEq(shield.feeRecipient(), treasury);
        assertTrue(shield.isEnforcer(enforcer), "freeze switch armed from the first block");
        assertEq(shield.owner(), deployer, "the deployer is admin until the owner accepts");
        assertEq(shield.pendingOwner(), owner);

        vm.prank(owner);
        shield.acceptOwnership();
        assertEq(shield.owner(), owner);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        shield.setAdapter(address(aave), false);
        // The owner is the admin, not an enforcer: it can neither freeze nor make itself one.
        vm.prank(owner);
        vm.expectRevert(ISignoShield.NotEnforcer.selector);
        shield.freezeAgent(deployer);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdminCannotBeEnforcer.selector, owner));
        shield.setEnforcer(owner, true);
        // The enforcer appointed at deployment can.
        vm.prank(enforcer);
        shield.freezeAgent(deployer);
        assertTrue(shield.isAgentFrozen(deployer));
    }

    function test_deploy_refusesAnEnforcerThatIsTheOwner() public {
        Deploy deploy = new Deploy();
        vm.expectRevert("ENFORCER must be neither deployer nor owner");
        deploy.deployWith(owner, treasury, owner, 10);
    }

    function test_deploy_refusesAFeeOutOfRange() public {
        Deploy deploy = new Deploy();
        vm.expectRevert("SHIELD_FEE_BPS out of range");
        deploy.deployWith(owner, treasury, enforcer, 70_000);
    }
}

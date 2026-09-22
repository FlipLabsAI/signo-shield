// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// The v1 deployment script against a fork of X Layer: everything listed,
/// the catalog resolvable by content id, ownership offered to the owner.
import {Test} from "forge-std/Test.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";

contract DeployV1ForkTest is Test {
    function test_deploysListsAndHandsOver() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), 70_752_723);
        address owner = makeAddr("owner");
        address enforcer = makeAddr("enforcer");
        DeployV1 deploy = new DeployV1();
        DeployV1.Deployed memory d = deploy.deployWith(owner, owner, enforcer, 10);
        assertTrue(d.registry.isExecutorListed(address(d.generic)));
        assertTrue(d.registry.isExecutorListed(address(d.aave)));
        assertTrue(d.registry.isEvaluatorListed(address(d.evaluator)));
        assertTrue(d.registry.isEnforcer(enforcer));
        assertEq(d.shield.pendingOwner(), owner);
        assertEq(d.registry.pendingOwner(), owner);
        assertEq(address(d.shield.registry()), address(d.registry));
        assertEq(d.shield.feeBps(), 10);
        // the ETH/USD feed descriptor resolves by its content id and is listed
        IDescriptors.Descriptor memory feed = IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.PerAddress,
            target: 0x8b85b50535551F8E8cDAF78dA235b5Cf1005907b,
            selector: bytes4(keccak256("latestRoundData()")),
            argCount: 0,
            subjectArg: -1,
            subjectRule: IDescriptors.SubjectRule.None,
            word: 1,
            isSigned: true,
            mustBePositive: true,
            decimals: 8,
            freshness: IDescriptors.Freshness.ChainlinkRound,
            maxAge: 3600,
            gasStipend: 160_000,
            copyBytes: 160
        });
        bytes32 id = d.registry.descriptorId(feed);
        (IDescriptors.Descriptor memory got, bool listed, bool revoked) = d.registry.descriptorOf(id);
        assertTrue(listed);
        assertFalse(revoked);
        assertEq(got.target, feed.target);
        assertEq(got.maxAge, 3600);
    }
}

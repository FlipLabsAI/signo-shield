// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// The v1 deployment script against a fork of Arbitrum One: everything listed,
/// every bound price round fresh and positive at the fork block, the sequencer
/// read listed and "up", ownership offered to the owner.
import {Test} from "forge-std/Test.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";

interface IRound {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract DeployV1ArbitrumForkTest is Test {
    DeployV1 internal deploy;
    DeployV1.Deployed internal d;
    address internal owner;

    function setUp() public {
        // Pinned 30 Sep 2026 (the day the Arbitrum catalog was read); an archive RPC is needed.
        vm.createSelectFork(
            vm.envOr("ARBITRUM_RPC_URL", string("https://arbitrum-one.public.blastapi.io")),
            vm.envOr("ARBITRUM_FORK_BLOCK", uint256(510428306))
        );
        deploy = new DeployV1();
        owner = makeAddr("owner");
        d = deploy.deployWith(owner, owner, address(0), 10);
    }

    function test_listsAndHandsOver() public view {
        assertEq(block.chainid, 42_161);
        assertTrue(d.registry.isExecutorListed(address(d.generic)));
        assertTrue(d.registry.isExecutorListed(address(d.aave)));
        assertTrue(d.registry.isExecutorListed(address(d.claims)));
        assertTrue(d.registry.isEvaluatorListed(address(d.evaluator)));
        assertEq(d.registry.pendingOwner(), owner);
        assertEq(d.shield.feeBps(), 10);
        assertEq(address(d.aave.pool()), 0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    }

    function test_everyBoundRoundIsFreshAndPositive() public view {
        address[9] memory tokens = [
            deploy.ARB_WETH(),
            deploy.ARB_WBTC(),
            deploy.ARB_USDC(),
            deploy.ARB_USDC_E(),
            deploy.ARB_USDT0(),
            deploy.ARB_DAI(),
            deploy.ARB_ARB(),
            deploy.ARB_LINK(),
            deploy.ARB_AAVE()
        ];
        for (uint256 i = 0; i < tokens.length; i++) {
            (bytes32 id, address feed) = d.registry.priceRound(tokens[i]);
            assertTrue(id != bytes32(0), "round bound");
            (IDescriptors.Descriptor memory desc, bool listed,) = d.registry.descriptorOf(id);
            assertTrue(listed, "round listed");
            assertEq(desc.target, feed);
            assertEq(uint8(desc.freshness), uint8(IDescriptors.Freshness.ChainlinkRound));
            (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                IRound(feed).latestRoundData();
            assertGt(answer, 0, "positive");
            assertLe(block.timestamp - updatedAt, desc.maxAge, "fresh within maxAge");
            assertGe(answeredInRound, roundId);
            // the read fits its stipend with room to spare
            uint256 g = gasleft();
            IRound(feed).latestRoundData();
            assertLt(g - gasleft(), desc.gasStipend / 2, "stipend");
        }
    }

    function test_sequencerReadListedAndUp() public view {
        bytes32 id = d.registry.descriptorId(deploy.sequencerUp(deploy.ARB_SEQUENCER_UPTIME()));
        (, bool listed, bool revoked) = d.registry.descriptorOf(id);
        assertTrue(listed);
        assertFalse(revoked);
        (, int256 answer,,,) = IRound(deploy.ARB_SEQUENCER_UPTIME()).latestRoundData();
        assertEq(answer, 0, "sequencer up at the fork block");
    }
}

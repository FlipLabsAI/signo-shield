// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// The BNB testnet demo against a fork of BNB testnet (chain 97). The Atlas
/// testnet feed refuses a contract caller that is not on its allowlist, as on
/// mainnet. From the team deployer's nonce 0 the evaluator lands at the mainnet
/// address 0xc428…2B15. Once Atlas allowlists the evaluator (written into the
/// fork's storage here, the state Atlas's own setAuthorizedCallers call would leave),
/// the permission whose condition holds sends 0.001 WBNB with the 10 bps fee on
/// top, and the one whose condition does not hold is refused.
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DemoAtlasBnbTestnet} from "script/DemoAtlasBnbTestnet.s.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";

interface IAtlasFeed {
    function isAuthorizedCaller(address caller) external view returns (bool);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract DemoAtlasBnbTestnetForkTest is Test {
    address internal constant DEPLOYER = 0xD56f87d6F4cbA5611A7C0954949Ff2EAa81bf4F9;
    address internal constant EVALUATOR = 0xc428a88A92Ecec99414152Ad2A5fd4244b222B15;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DemoAtlasBnbTestnet internal script;
    IAtlasFeed internal feed;
    address internal deployer;
    address internal principal;
    address internal recipient;

    function setUp() public {
        // The latest block unless pinned: the testnet public node may refuse older state.
        string memory rpc = vm.envOr("BNB_TESTNET_RPC_URL", string("https://bsc-testnet-rpc.publicnode.com"));
        uint256 pinned = vm.envOr("BNB_TESTNET_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        script = new DemoAtlasBnbTestnet();
        feed = IAtlasFeed(script.ATLAS_BNB_USD_TESTNET());
        principal = makeAddr("principal");
        recipient = makeAddr("recipient");
        // A fresh deployer: after the real run the team deployer's addresses
        // are taken on the fork, so the flow runs from another key.
        deployer = makeAddr("deployer");
        vm.deal(deployer, 0.05 ether);
    }

    function test_theTestnetFeedRefusesAContractNotOnItsAllowlist() public {
        assertEq(block.chainid, 97);
        assertEq(
            vm.computeCreateAddress(DEPLOYER, 2), EVALUATOR, "the evaluator lands at the mainnet address"
        );
        vm.expectRevert(bytes4(keccak256("OnlyAuthorizedCallerAllowed()")));
        feed.latestRoundData();
    }

    function test_theFeedIsAtlasBnbUsdAt18DecimalsAndFresh() public {
        _allowOnAtlas(address(this));
        assertEq(feed.decimals(), 18);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertGt(answer, 100e18, "BNB above $100");
        assertLt(answer, 100_000e18, "and a sane price");
        assertLe(block.timestamp - updatedAt, 600, "fresh within the read's ten heartbeats");
        assertGe(answeredInRound, roundId);
    }

    function test_beforeTheAllowlistRegistrationReverts() public {
        if (feed.isAuthorizedCaller(vm.computeCreateAddress(deployer, 2))) return;
        vm.expectRevert();
        script.demo(deployer, principal, recipient);
    }

    function test_firesWhenAtlasSaysBnbIsAbove100_andRefusesAbove1M() public {
        address evaluator = vm.computeCreateAddress(deployer, 2);
        _allowOnAtlas(evaluator);
        DemoAtlasBnbTestnet.Demo memory d = script.demo(deployer, principal, recipient);
        assertEq(address(d.evaluator), evaluator);

        (IDescriptors.Descriptor memory desc, bool listed, bool revoked) =
            d.registry.descriptorOf(d.atlasRead);
        assertTrue(listed);
        assertFalse(revoked);
        assertEq(desc.target, address(feed));
        assertEq(desc.decimals, 18);

        uint256 amount = script.AMOUNT();
        uint256 fee = amount * script.FEE_BPS() / 10_000;
        address wbnb = script.WBNB_TESTNET();
        assertEq(IERC20(wbnb).balanceOf(recipient), amount, "the recipient got 0.001 WBNB");
        assertEq(IERC20(wbnb).balanceOf(deployer), fee, "10 bps to the fee recipient");
        assertEq(d.spent, amount + fee, "spent = sent + fee");
        assertEq(IERC20(wbnb).balanceOf(address(d.generic)), 0, "nothing left in the executor");
        assertEq(IERC20(wbnb).balanceOf(address(d.shield)), 0, "nothing left in the core");

        // The second permission's condition (BNB above $1,000,000) is false: refused.
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, d.refuses, IShieldV1.MandateReason.TRIGGER_NOT_MET
            )
        );
        d.shield.fire(d.refuses, amount, "");

        // And the first is spent: its budget was one firing.
        vm.prank(deployer);
        vm.expectRevert();
        d.shield.fire(d.fires, amount, "");
    }

    /// @dev Allowlist `caller` on the fork: set the slot(s) `isAuthorizedCaller(caller)`
    ///      reads, other than the proxy's implementation slot.
    function _allowOnAtlas(address caller) internal {
        vm.record();
        feed.isAuthorizedCaller(caller);
        (bytes32[] memory reads,) = vm.accesses(address(feed));
        for (uint256 i = 0; i < reads.length; i++) {
            if (reads[i] != IMPL_SLOT) vm.store(address(feed), reads[i], bytes32(uint256(1)));
        }
        assertTrue(feed.isAuthorizedCaller(caller), "allowlisted on the fork");
    }
}

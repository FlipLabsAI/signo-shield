// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// The BNB testnet demo against a fork of BNB testnet (chain 97). Atlas's open
/// testnet feeds answer a contract caller with no allowlist entry (the feed on
/// Atlas's public page does not: OnlyAuthorizedCallerAllowed, as on mainnet).
/// The permission whose condition holds sends 0.001 WBNB with the 10 bps fee
/// on top, and the one whose condition does not hold is refused.
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DemoAtlasBnbTestnet} from "script/DemoAtlasBnbTestnet.s.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";

interface IAtlasFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

contract DemoAtlasBnbTestnetForkTest is Test {
    /// The feed on atlasoracle.io/feeds/633 for BNB testnet: allowlisted callers only.
    address internal constant ATLAS_PAGE_BNB_USD = 0xb3d1614Bf894E68ADd1EA50CA250C152BAd5256F;

    DemoAtlasBnbTestnet internal script;
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
        // Fresh keys: after the real run the team deployer's addresses are taken on the fork.
        deployer = makeAddr("deployer");
        principal = makeAddr("principal");
        recipient = makeAddr("recipient");
        vm.deal(deployer, 0.05 ether);
    }

    function test_theOpenFeedsAnswerAContractAt18DecimalsAndFresh() public view {
        assertEq(block.chainid, 97);
        address[3] memory feeds =
            [script.ATLAS_BNB_USD_TESTNET(), script.ATLAS_BTC_USD_TESTNET(), script.ATLAS_ETH_USD_TESTNET()];
        string[3] memory names = ["SingleFeed BNB/USD", "SingleFeed BTC/USD", "SingleFeed ETH/USD"];
        for (uint256 i = 0; i < feeds.length; i++) {
            IAtlasFeed feed = IAtlasFeed(feeds[i]);
            assertEq(feed.description(), names[i]);
            assertEq(feed.decimals(), 18);
            // This test contract is a contract caller with no allowlist entry.
            (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                feed.latestRoundData();
            assertGt(answer, 0, "positive");
            assertLe(block.timestamp - updatedAt, 600, "fresh within the read's ten heartbeats");
            assertGe(answeredInRound, roundId);
        }
    }

    function test_theFeedOnAtlasPageRefusesAContractNotOnItsAllowlist() public {
        vm.expectRevert(bytes4(keccak256("OnlyAuthorizedCallerAllowed()")));
        IAtlasFeed(ATLAS_PAGE_BNB_USD).latestRoundData();
    }

    function test_firesWhenAtlasSaysBnbIsAbove100_andRefusesAbove1M() public {
        DemoAtlasBnbTestnet.Demo memory d = script.demo(deployer, principal, recipient);

        (IDescriptors.Descriptor memory desc, bool listed, bool revoked) =
            d.registry.descriptorOf(d.atlasRead);
        assertTrue(listed);
        assertFalse(revoked);
        assertEq(desc.target, script.ATLAS_BNB_USD_TESTNET());
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
}

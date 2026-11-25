// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// The v1 deployment script against a fork of BNB Chain: everything listed,
/// every bound price round fresh and positive at the fork block, the Atlas
/// reads listed at 18 decimals and fresh, ownership offered to the owner, and
/// one USDT supply to Aave fired through the deployed Shield behind a trigger
/// that reads the Atlas BNB/USD feed on chain.
///
/// Atlas feeds answer only allowlisted contract callers
/// (`OnlyAuthorizedCallerAllowed`; Atlas sets them with `setAuthorizedCallers`).
/// The tests allowlist a caller on the fork by writing the slot that
/// `isAuthorizedCaller` reads, the state Atlas's own call would leave.
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";

interface IRound {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IAtlasFeed {
    function isAuthorizedCaller(address caller) external view returns (bool);
}

contract DeployV1BnbForkTest is Test {
    address internal constant POOL = 0x6807dc923806fE8Fd134338EABCA509979a7e0cB;
    address internal constant A_USDT = 0xa9251ca9DE909CB71783723713B21E4233fbf1B1;
    bytes32 internal constant SUPPLY = keccak256("aave-v3.supply");

    DeployV1 internal deploy;
    DeployV1.Deployed internal d;
    address internal owner;

    function setUp() public {
        // Pinned 25 Nov 2026 (the day the BNB Chain catalog was read); an archive RPC is needed.
        vm.createSelectFork(
            vm.envOr("BNB_RPC_URL", string("https://bsc-rpc.publicnode.com")),
            vm.envOr("BNB_FORK_BLOCK", uint256(135_641_450))
        );
        deploy = new DeployV1();
        owner = makeAddr("owner");
        d = deploy.deployWith(owner, owner, address(0), 10);
    }

    function test_listsAndHandsOver() public view {
        assertEq(block.chainid, 56);
        assertTrue(d.registry.isExecutorListed(address(d.generic)));
        assertTrue(d.registry.isExecutorListed(address(d.aave)));
        assertTrue(d.registry.isExecutorListed(address(d.claims)));
        assertTrue(d.registry.isEvaluatorListed(address(d.evaluator)));
        assertEq(d.registry.pendingOwner(), owner);
        assertEq(d.shield.feeBps(), 10);
        assertEq(address(d.aave.pool()), POOL);
    }

    function test_everyBoundRoundIsFreshAndPositive() public view {
        address[7] memory tokens = [
            deploy.BNB_WBNB(),
            deploy.BNB_BTCB(),
            deploy.BNB_ETH(),
            deploy.BNB_USDC(),
            deploy.BNB_USDT(),
            deploy.BNB_FDUSD(),
            deploy.BNB_CAKE()
        ];
        for (uint256 i = 0; i < tokens.length; i++) {
            (bytes32 id, address feed) = d.registry.priceRound(tokens[i]);
            assertTrue(id != bytes32(0), "round bound");
            (IDescriptors.Descriptor memory desc, bool listed,) = d.registry.descriptorOf(id);
            assertTrue(listed, "round listed");
            assertEq(desc.target, feed);
            assertEq(uint8(desc.freshness), uint8(IDescriptors.Freshness.ChainlinkRound));
            assertEq(IRound(feed).decimals(), desc.decimals, "decimals match the feed");
            (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                IRound(feed).latestRoundData();
            assertGt(answer, 0, "positive");
            assertLe(updatedAt, block.timestamp, "not from the future");
            assertLe(block.timestamp - updatedAt, desc.maxAge, "fresh within maxAge");
            assertGe(answeredInRound, roundId);
            uint256 g = gasleft();
            IRound(feed).latestRoundData();
            assertLt(g - gasleft(), desc.gasStipend / 2, "stipend");
        }
    }

    function test_atlasRefusesAContractNotOnItsAllowlist() public {
        address feed = deploy.ATLAS_BNB_USD();
        assertFalse(IAtlasFeed(feed).isAuthorizedCaller(address(d.evaluator)));
        vm.expectRevert(bytes4(keccak256("OnlyAuthorizedCallerAllowed()")));
        IRound(feed).latestRoundData();
    }

    function test_atlasReadsListedFreshAt18Decimals() public {
        address[3] memory feeds = [deploy.ATLAS_BNB_USD(), deploy.ATLAS_BTC_USD(), deploy.ATLAS_ETH_USD()];
        for (uint256 i = 0; i < feeds.length; i++) {
            _allowOnAtlas(feeds[i], address(this));
            bytes32 id = d.registry.descriptorId(deploy.atlasRound(feeds[i]));
            (IDescriptors.Descriptor memory desc, bool listed, bool revoked) = d.registry.descriptorOf(id);
            assertTrue(listed, "atlas read listed");
            assertFalse(revoked);
            assertEq(desc.decimals, 18);
            assertEq(IRound(feeds[i]).decimals(), 18, "Atlas feeds carry 18 decimals");
            (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                IRound(feeds[i]).latestRoundData();
            assertGt(answer, 0, "positive");
            assertLe(updatedAt, block.timestamp, "not from the future");
            assertLe(block.timestamp - updatedAt, desc.maxAge, "fresh within maxAge");
            assertGe(answeredInRound, roundId);
        }
    }

    /// "When BNB is above $100 (Atlas, on chain), supply up to 5 USDT to Aave."
    function test_supplyUsdtToAave_behindAnAtlasTrigger() public {
        // The deploy handed the admin seat over; accept it to set the fee recipient as the owner would.
        vm.prank(owner);
        d.registry.acceptOwnership();
        address principal = makeAddr("principal");
        address agent = makeAddr("agent");
        address usdt = deploy.BNB_USDT();
        deal(usdt, principal, 20e18);
        vm.prank(principal);
        IERC20(usdt).approve(address(d.shield), type(uint256).max);

        IShieldV1.MandateParams memory p;
        p.agent = agent;
        p.executor = address(d.aave);
        p.evaluator = address(d.evaluator);
        p.action = SUPPLY;
        p.asset = usdt;
        p.maxTransactionValue = 5e18;
        p.maxCumulativeValue = 10e18;
        p.validFrom = 0;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.maxFeeBps = 10;
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.trigger = _atlasBnbAbove(100e18);

        // Before Atlas allowlists the evaluator the read fails, and registration
        // (which reads the tree once) refuses the mandate.
        vm.prank(principal);
        vm.expectRevert();
        d.shield.registerMandate(p);

        _allowOnAtlas(deploy.ATLAS_BNB_USD(), address(d.evaluator));
        vm.prank(principal);
        bytes32 id = d.shield.registerMandate(p);
        (bool ok,) = d.shield.canFireBy(id, agent, 5e18);
        assertTrue(ok, "mandate checks pass (canFireBy does not read the trigger)");
        uint256 aBefore = IERC20(A_USDT).balanceOf(principal);
        uint256 feeBefore = IERC20(usdt).balanceOf(owner);
        vm.prank(agent);
        uint256 spent = d.shield.fire(id, 5e18, "");
        uint256 fee = IERC20(usdt).balanceOf(owner) - feeBefore;
        assertEq(fee, 5e18 * 10 / 10_000, "10 bps to the fee recipient, on top");
        assertEq(spent, 5e18 + fee, "spent = supplied + fee");
        assertApproxEqAbs(IERC20(A_USDT).balanceOf(principal) - aBefore, 5e18, 2, "aUSDT rose by the supply");
        assertEq(IERC20(usdt).balanceOf(address(d.aave)), 0, "nothing left in the adapter");
        assertEq(IERC20(usdt).balanceOf(address(d.shield)), 0, "nothing left in the core");

        // A trigger that is false refuses: BNB above $1,000,000.
        p.trigger = _atlasBnbAbove(1_000_000e18);
        vm.prank(principal);
        bytes32 id2 = d.shield.registerMandate(p);
        vm.prank(agent);
        vm.expectRevert();
        d.shield.fire(id2, 5e18, "");
    }

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Allowlist `caller` on an Atlas feed on the fork: set the slot(s)
    ///      `isAuthorizedCaller(caller)` reads, other than the proxy's implementation slot.
    function _allowOnAtlas(address feed, address caller) internal {
        vm.record();
        IAtlasFeed(feed).isAuthorizedCaller(caller);
        (bytes32[] memory reads,) = vm.accesses(feed);
        for (uint256 i = 0; i < reads.length; i++) {
            if (reads[i] != IMPL_SLOT) vm.store(feed, reads[i], bytes32(uint256(1)));
        }
        assertTrue(IAtlasFeed(feed).isAuthorizedCaller(caller), "allowlisted on the fork");
    }

    function _atlasBnbAbove(uint256 usd18) internal view returns (bytes memory) {
        address feed = deploy.ATLAS_BNB_USD();
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: d.registry.descriptorId(deploy.atlasRound(feed)),
            target: feed,
            args: "",
            subject: ExprLib.Subject.None,
            decimals: 18
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: usd18, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.GT), a: 0, b: 1});
        return abi.encode(r, n);
    }
}

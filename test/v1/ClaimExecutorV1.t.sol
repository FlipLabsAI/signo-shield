// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {ClaimExecutorV1} from "contracts/v1/ClaimExecutorV1.sol";
import {MockToken} from "./mocks/MockExecutor.sol";

/// A Pendle-like market: anyone may trigger `redeemRewards(user)`; it pays `user`
/// what the market owes, less `shortBps` when set (a venue that underpays).
contract MockRewardMarket {
    MockToken public immutable reward;
    mapping(address => uint256) public owed;
    uint256 public shortBps;

    constructor(MockToken r) {
        reward = r;
    }

    function setOwed(address u, uint256 v) external {
        owed[u] = v;
    }

    function setShort(uint256 bps) external {
        shortBps = bps;
    }

    /// Same shape as Pendle's `userReward(token, user)`: (index, accrued).
    function userReward(address, address user) external view returns (uint128 index, uint128 accrued) {
        return (1, uint128(owed[user]));
    }

    function redeemRewards(address user) external returns (uint256[] memory out) {
        uint256 v = owed[user];
        owed[user] = 0;
        uint256 paid = v - v * shortBps / 10_000;
        reward.mint(user, paid);
        out = new uint256[](1);
        out[0] = paid;
    }
}

/// Collect-only claims through listed claim rules (FLIP-280 F1/F2, 23 Sep).
contract ClaimExecutorV1Test is Test {
    ShieldV1 internal shield;
    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    ClaimExecutorV1 internal exec;
    MockToken internal reward;
    MockRewardMarket internal market;
    bytes32 internal ruleId;
    bytes32 internal accruedId;

    address internal admin = address(0xAD);
    address internal enforcer = address(0xE0);
    address internal principal = address(0xA11CE);
    address internal agent = address(0xA6E);
    address internal stranger = address(0xB0B);
    bytes32 internal constant COLLECT = keccak256("claim.collect");

    function setUp() public {
        registry = new ShieldRegistryV1(admin);
        shield = new ShieldV1(registry, 0);
        ev = new ExpressionEvaluator(registry);
        exec = new ClaimExecutorV1(address(shield));
        reward = new MockToken();
        market = new MockRewardMarket(reward);
        vm.startPrank(admin);
        registry.setExecutor(address(exec), true);
        registry.setEvaluator(address(ev), true);
        registry.setEnforcer(enforcer, true);
        ruleId = registry.listClaimRule(_rule(address(market)));
        accruedId = registry.listDescriptor(_accrued(address(market)));
        vm.stopPrank();
        market.setOwed(principal, 100e18);
        market.setOwed(stranger, 7e18);
    }

    function _rule(address m) internal pure returns (IShieldRegistryV1.ClaimRule memory r) {
        r.target = m;
        r.selector = MockRewardMarket.redeemRewards.selector;
        r.argCount = 1;
        r.ownerArgs = 1;
        r.args = abi.encode(address(0));
    }

    function _accrued(address m) internal pure returns (IDescriptors.Descriptor memory d) {
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = m;
        d.selector = MockRewardMarket.userReward.selector;
        d.argCount = 2;
        d.subjectArg = 1;
        d.subjectRule = IDescriptors.SubjectRule.PrincipalRequired;
        d.word = 1;
        d.decimals = 18;
        d.gasStipend = 100_000;
        d.copyBytes = 64;
    }

    function _cfg() internal view returns (ClaimExecutorV1.Config memory c) {
        c.claims = new bytes32[](1);
        c.claims[0] = ruleId;
        c.rewardTokens = new address[](1);
        c.rewardTokens[0] = address(reward);
        c.claimable = new ExprLib.Read[](1);
        c.claimable[0] = ExprLib.Read(
            accruedId, address(market), abi.encode(address(reward), address(0)), ExprLib.Subject.Principal, 18
        );
        c.dust = 0;
    }

    function _params(ClaimExecutorV1.Config memory c)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(exec),
            evaluator: address(ev),
            asset: address(reward),
            maxTransactionValue: 0,
            maxCumulativeValue: 0,
            validFrom: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 0,
            funding: uint8(IShieldV1.FundingMode.NONE),
            action: COLLECT,
            actionConfig: abi.encode(uint8(1), c),
            trigger: "",
            outcome: ""
        });
    }

    function _register(ClaimExecutorV1.Config memory c) internal returns (bytes32 id) {
        IShieldV1.MandateParams memory p = _params(c);
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _outcome(bytes32 id, bytes memory err) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, err
            )
        );
    }

    // ------------------------------------------------------------------ collect

    function test_collectPaysTheOwnerThroughTheRuleNothingPulled() public {
        bytes32 id = _register(_cfg());
        vm.prank(agent);
        assertEq(shield.fire(id, 0, ""), 0);
        assertEq(reward.balanceOf(principal), 100e18);
        assertEq(market.owed(principal), 0);
        assertEq(market.owed(stranger), 7e18, "only the owner's own claim ran");
        assertEq(shield.getMandate(id).cumulativeUsed, 0);
    }

    function test_agentCallsAreRefused() public {
        bytes32 id = _register(_cfg());
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = IExecutorV1.Call(
            address(market),
            address(0),
            address(0),
            0,
            true,
            abi.encodeCall(MockRewardMarket.redeemRewards, (stranger))
        );
        _outcome(id, abi.encodeWithSelector(ClaimExecutorV1.RouteInvalid.selector, "route"));
        vm.prank(agent);
        shield.fire(id, 0, abi.encode(calls));
        assertEq(market.owed(principal), 100e18);
        assertEq(market.owed(stranger), 7e18);
    }

    function test_aVenuePayingLessThanClaimableIsRefused() public {
        bytes32 id = _register(_cfg());
        market.setShort(1_000); // pays 90 of the 100 it reports as accrued
        _outcome(
            id,
            abi.encodeWithSelector(ClaimExecutorV1.BelowClaimable.selector, address(reward), 90e18, 100e18)
        );
        vm.prank(agent);
        shield.fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 0);
        assertEq(market.owed(principal), 100e18);
    }

    function test_dustAllowsThatMuchLessAndNothingAtOrBelowItIsAClaim() public {
        ClaimExecutorV1.Config memory c = _cfg();
        c.dust = 1e18;
        bytes32 id = _register(c);
        market.setShort(50); // pays 99.5 of 100: within the 1-token dust
        vm.prank(agent);
        shield.fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 99.5e18);
        market.setOwed(principal, 1e18); // a claim of exactly the dust is not a claim
        _outcome(id, abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, address(reward)));
        vm.prank(agent);
        shield.fire(id, 0, "");
    }

    function test_nothingOwedIsNothingClaimed() public {
        bytes32 id = _register(_cfg());
        market.setOwed(principal, 0);
        _outcome(id, abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, address(reward)));
        vm.prank(agent);
        shield.fire(id, 0, "");
    }

    function test_anAmountIsRefused() public {
        bytes32 id = _register(_cfg());
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.AMOUNT_NOT_ZERO
            )
        );
        shield.fire(id, 1, "");
    }

    // ------------------------------------------------------------- stops reach it

    function test_aRevokedRuleStopsTheLiveMandate() public {
        bytes32 id = _register(_cfg());
        vm.prank(enforcer);
        registry.revokeClaimRule(ruleId);
        _outcome(id, abi.encodeWithSelector(ClaimExecutorV1.ClaimRuleRevoked.selector, ruleId));
        vm.prank(agent);
        shield.fire(id, 0, "");
        assertEq(market.owed(principal), 100e18);
    }

    function test_aDelistedRuleKeepsTheLiveMandateButRefusesNewOnes() public {
        bytes32 id = _register(_cfg());
        vm.prank(admin);
        registry.delistClaimRule(ruleId);
        vm.prank(agent);
        shield.fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 100e18);
        IShieldV1.MandateParams memory p = _params(_cfg());
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ClaimExecutorV1.ConfigInvalid.selector, "claim:rule"));
        shield.registerMandate(p);
    }

    function test_aSuspendedVenueStopsTheClaim() public {
        bytes32 id = _register(_cfg());
        vm.prank(enforcer);
        registry.suspend(address(market));
        // The claimable read hits the suspended market first, before any claim runs.
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        vm.prank(agent);
        shield.fire(id, 0, "");
    }

    // ---------------------------------------------------------------- admission

    function test_composeIsNotAnAction() public {
        IShieldV1.MandateParams memory p = _params(_cfg());
        p.action = keccak256("claim.compose");
        vm.prank(principal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.ActionNotSupported.selector, address(exec), keccak256("claim.compose")
            )
        );
        shield.registerMandate(p);
    }

    function test_admissionRefusesUnlistedRulesDuplicatesAndBadClaimableReads() public {
        ClaimExecutorV1.Config memory c = _cfg();
        c.claims[0] = keccak256("not listed");
        _refused(c, "claim:rule");
        c = _cfg();
        c.claims = new bytes32[](2);
        c.claims[0] = ruleId;
        c.claims[1] = ruleId;
        _refused(c, "claim:duplicate");
        c = _cfg();
        c.claimable = new ExprLib.Read[](0);
        _refused(c, "claimable");
        c = _cfg();
        c.claimable[0].subject = ExprLib.Subject.Explicit;
        _refusedTree(c, "subject");
        c = _cfg();
        c.claimable[0].args = abi.encode(address(reward), stranger); // the owner word must be left zero
        IShieldV1.MandateParams memory p = _params(c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        shield.registerMandate(p);
    }

    function _refused(ClaimExecutorV1.Config memory c, string memory field) internal {
        IShieldV1.MandateParams memory p = _params(c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ClaimExecutorV1.ConfigInvalid.selector, field));
        shield.registerMandate(p);
    }

    function _refusedTree(ClaimExecutorV1.Config memory c, string memory field) internal {
        IShieldV1.MandateParams memory p = _params(c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, field));
        shield.registerMandate(p);
    }

    // ------------------------------------------------------------ the registry

    function test_registryListsOnlyRulesThatLeaveTheOwnerWordsBlank() public {
        IShieldRegistryV1.ClaimRule memory r = _rule(address(market));
        r.args = abi.encode(stranger);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("ownerWord"))
        );
        registry.listClaimRule(r);
        r = _rule(address(market));
        r.ownerArgs = 2; // argument 1 does not exist
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("ownerArgs"))
        );
        registry.listClaimRule(r);
        r = _rule(address(market));
        r.ownerArgs = 0;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("ownerArgs"))
        );
        registry.listClaimRule(r);
        r = _rule(address(0xDEAD));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("target")));
        registry.listClaimRule(r);
        r = _rule(address(market));
        r.argCount = 2;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("args")));
        registry.listClaimRule(r);
    }

    function test_onlyTheAdminListsAndOnlyAnEnforcerRevokesForGood() public {
        vm.prank(enforcer);
        vm.expectRevert();
        registry.listClaimRule(_rule(address(market)));
        vm.prank(admin);
        vm.expectRevert(IShieldRegistryV1.NotEnforcer.selector);
        registry.revokeClaimRule(ruleId);
        vm.prank(enforcer);
        registry.revokeClaimRule(ruleId);
        (, bool listed, bool revoked) = registry.claimRuleOf(ruleId);
        assertFalse(listed);
        assertTrue(revoked);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("revoked")));
        registry.listClaimRule(_rule(address(market)));
    }

    function test_theIdIsTheContents() public view {
        (IShieldRegistryV1.ClaimRule memory r,,) = registry.claimRuleOf(ruleId);
        assertEq(ruleId, keccak256(abi.encode(r)));
        assertEq(r.target, address(market));
        assertEq(r.selector, MockRewardMarket.redeemRewards.selector);
    }
}

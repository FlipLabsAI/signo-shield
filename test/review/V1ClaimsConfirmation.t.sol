// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V1ReviewBase} from "./V1ReviewBase.sol";
import {MockToken} from "test/v1/mocks/MockExecutor.sol";
import {MockDistributor} from "test/v1/mocks/MockVenues.sol";
import {ClaimExecutorV1} from "contracts/v1/ClaimExecutorV1.sol";
import {DisposableCloneV1} from "contracts/v1/DisposableCloneV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IExecutorV1, SemanticsV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";

contract ClaimsConfirmationVenue {
    MockToken public immutable reward;
    MockToken public immutable bonus;
    uint256 public reported = 100e18;
    uint256 public paid = 100e18;
    uint256 public bonusPaid;
    uint256 public calls;
    bool public failRead;
    bool public shortRead;
    address public lastCaller;
    bytes32 public expectedCall;
    address public expectedOwner;

    constructor(MockToken r, MockToken b) {
        reward = r;
        bonus = b;
    }

    function configure(uint256 report_, uint256 paid_, uint256 bonus_) external {
        reported = report_;
        paid = paid_;
        bonusPaid = bonus_;
    }

    function readFailure(bool fail, bool short_) external {
        failRead = fail;
        shortRead = short_;
    }

    function claimable(address) external view returns (uint256) {
        require(!failRead, "read failed");
        if (shortRead) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return reported;
    }

    function collect(address owner, address receiver) external {
        require(owner != address(0), "owner");
        calls++;
        reported = 0;
        lastCaller = msg.sender;
        reward.mint(receiver, paid);
    }

    function callerPaid(address owner) external {
        require(owner != address(0), "owner");
        calls++;
        reported = 0;
        lastCaller = msg.sender;
        reward.mint(msg.sender, paid);
        bonus.mint(msg.sender, bonusPaid);
    }

    function oldAuthority(address owner, address token, address receiver) external {
        MockToken(token).transferFrom(owner, receiver, 10e18);
        reward.mint(owner, paid);
    }

    function sandboxPull(address owner) external {
        reward.transferFrom(msg.sender, address(0xBAD), 1);
        reward.mint(owner, paid);
    }

    function expectCall(bytes memory data, address owner) external {
        expectedCall = keccak256(data);
        expectedOwner = owner;
    }

    fallback() external {
        require(keccak256(msg.data) == expectedCall, "wrong call words");
        calls++;
        lastCaller = msg.sender;
        reward.mint(expectedOwner, paid);
    }
}

/// Copies argument words into return words, so a descriptor can select any bound word.
contract ClaimsEchoRead {
    fallback(bytes calldata data) external returns (bytes memory) {
        return data[4:];
    }
}

contract ClaimsRecipeHarness {
    function read(ExprLib.Read memory r, address owner, IDescriptors catalog) external view returns (int256) {
        ExprLib.checkRecipeRead(r, catalog);
        bytes memory originalArgs = r.args;
        bytes32 beforeHash = keccak256(originalArgs);
        int256 result = ExprLib.readAbout(r, owner, 0, catalog);
        require(keccak256(originalArgs) == beforeHash, "read overwrote original argument words");
        return result;
    }
}

/// No deployment changes: a deliberately separately listed executor exposes the retained core semantics.
contract ClaimsLegacyComposeProbe is IExecutorV1 {
    uint256 public calls;

    function semanticsOf(bytes32) external pure returns (uint8) {
        return SemanticsV1.CLAIM_COMPOSE;
    }
    function validateConfig(bytes32, address, bytes calldata) external pure {}

    function snapshot(Context calldata, uint256) external pure returns (bytes memory) {
        return "";
    }

    function execute(Context calldata, uint256, bytes calldata) external returns (uint256) {
        calls++;
        return 0;
    }
}

contract V1ClaimsConfirmationTest is V1ReviewBase {
    ClaimsConfirmationVenue internal venue;
    bytes32 internal venueRule;
    bytes32 internal venueRead;

    function setUp() public override {
        super.setUp();
        venue = new ClaimsConfirmationVenue(reward, output);
        IShieldRegistryV1.ClaimRule memory r = _claimRule(address(venue));
        r.selector = venue.collect.selector;
        venueRule = registry.listClaimRule(r);
        venueRead = registry.listDescriptor(_claimableDescriptor(address(venue)));
    }

    function _config() internal view returns (ClaimExecutorV1.Config memory c) {
        c = _claimConfig();
        c.claims[0] = venueRule;
        c.claimable[0].descriptor = venueRead;
        c.claimable[0].target = address(venue);
    }

    function _reject(bytes32 id, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, reason
            )
        );
    }

    function _callerConfig() internal returns (ClaimExecutorV1.Config memory c) {
        IShieldRegistryV1.ClaimRule memory r = IShieldRegistryV1.ClaimRule(
            address(venue), venue.callerPaid.selector, 1, 1, abi.encode(address(0))
        );
        c = _config();
        c.claims[0] = registry.listClaimRule(r);
    }

    function test_snapshotPrecedesStateChangesAndFailureRollsBackEverything() public {
        venue.configure(100e18, 90e18, 0);
        bytes32 id = _register(_claimParams(_config()));
        address clone = claims.nextClone(id);
        _reject(
            id,
            abi.encodeWithSelector(ClaimExecutorV1.BelowClaimable.selector, address(reward), 90e18, 100e18)
        );
        _fire(id, 0, "");
        assertEq(venue.reported(), 100e18);
        assertEq(venue.calls(), 0);
        assertEq(reward.balanceOf(principal), 0);
        assertEq(clone.code.length, 0);
        assertEq(claims.firings(id), 0);
        assertEq(core.getMandate(id).firings, 0);
        assertEq(core.getMandate(id).lastFiredAt, 0);
    }

    function test_staleLowAndZeroReadsAreFloorsNotFullEntitlementProofs() public {
        venue.configure(1, 100e18, 0);
        bytes32 id = _register(_claimParams(_config()));
        _fire(id, 0, "");
        venue.configure(0, 100e18, 0);
        _fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 200e18);
        assertEq(core.getMandate(id).cumulativeUsed, 0);
    }

    function test_readRevertStopsBeforeClaimOrCloneCreation() public {
        bytes32 id = _register(_claimParams(_config()));
        venue.readFailure(true, false);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadFailed.selector, 0, bytes("")));
        _fire(id, 0, "");
        assertEq(venue.calls(), 0);
        assertEq(claims.firings(id), 0);
    }

    function test_shortReadStopsBeforeClaim() public {
        bytes32 id = _register(_claimParams(_config()));
        venue.readFailure(false, true);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadTooShort.selector, 0, 0, 32));
        _fire(id, 0, "");
        assertEq(venue.calls(), 0);
    }

    function testFuzz_exactDustFloorAndOneBelow(uint128 rawAmount, uint64 rawDust) public {
        uint256 amount = bound(uint256(rawAmount), 3, 1e30);
        uint256 dust = bound(uint256(rawDust), 0, (amount - 1) / 2);
        ClaimExecutorV1.Config memory c = _config();
        c.dust = dust;
        venue.configure(amount, amount - dust, 0);
        bytes32 id = _register(_claimParams(c));
        _fire(id, 0, "");
        venue.configure(amount, amount - dust - 1, 0);
        uint256 got = amount - dust - 1;
        if (got <= dust) {
            _reject(id, abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, address(reward)));
        } else {
            _reject(
                id,
                abi.encodeWithSelector(ClaimExecutorV1.BelowClaimable.selector, address(reward), got, amount)
            );
        }
        _fire(id, 0, "");
        assertEq(core.getMandate(id).firings, 1);
    }

    function test_callerPaidClaimIsSweptButIsNotDirectToOwner() public {
        bytes32 id = _register(_claimParams(_callerConfig()));
        address clone = claims.nextClone(id);
        _fire(id, 0, "");
        assertEq(venue.lastCaller(), clone);
        assertEq(reward.balanceOf(principal), 100e18);
        assertEq(reward.balanceOf(clone), 0);
        assertEq(reward.allowance(clone, address(venue)), 0);
        vm.prank(address(claims));
        vm.expectRevert(DisposableCloneV1.AlreadyUsed.selector);
        DisposableCloneV1(clone).finish(_config().rewardTokens, principal);
    }

    function test_declaredSecondTokenWithZeroPaymentRevertsTheWholeClaim() public {
        ClaimExecutorV1.Config memory c = _callerConfig();
        c.rewardTokens = new address[](2);
        c.rewardTokens[0] = address(reward);
        c.rewardTokens[1] = address(output);
        c.claimable = new ExprLib.Read[](2);
        c.claimable[0] = _config().claimable[0];
        c.claimable[1] =
            ExprLib.Read(balanceId, address(output), abi.encode(address(0)), ExprLib.Subject.Principal, 18);
        bytes32 id = _register(_claimParams(c));
        _reject(id, abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, address(output)));
        _fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 0);
        assertEq(venue.calls(), 0);
    }

    /// Round 7 (Austin, 23 Sep: "have the sandbox forward all rewards"): an undeclared
    /// caller-paid reward is no longer lost. The firing sweeps the declared tokens; anyone
    /// may then send any other token the used sandbox holds to the owner, and only to them.
    function test_fixUndeclaredCallerPaidRewardReachesTheOwner() public {
        venue.configure(100e18, 100e18, 7e18);
        bytes32 id = _register(_claimParams(_callerConfig()));
        address clone = claims.nextClone(id);
        _fire(id, 0, "");
        assertEq(output.balanceOf(clone), 7e18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(output);
        vm.prank(makeAddr("anyone"));
        DisposableCloneV1(clone).sendToOwner(tokens);
        assertEq(output.balanceOf(clone), 0);
        assertEq(output.balanceOf(principal), 7e18);
        assertEq(output.balanceOf(makeAddr("anyone")), 0);
        assertEq(DisposableCloneV1(clone).owner(), principal);
    }

    function test_boundaryFixedOtherReceiverCanPassWithDifferentReadAndSecondClaim() public {
        // Both rules are deliberately admin-listed and owner-signed. This is a recipe/venue
        // admission counterexample, NOT an unlisted agent route or an exploit of Pendle's rule.
        IShieldRegistryV1.ClaimRule memory bad = _claimRule(address(distributor));
        bad.ownerArgs = 1;
        bad.args = abi.encode(address(0), recipient);
        bytes32 badId = registry.listClaimRule(bad);
        distributor.setOwed(principal, 100e18);
        venue.configure(0, 1, 0);
        ClaimExecutorV1.Config memory c = _config();
        c.claims = new bytes32[](2);
        c.claims[0] = badId;
        c.claims[1] = venueRule;
        bytes32 id = _register(_claimParams(c));
        _fire(id, 0, "");
        assertEq(reward.balanceOf(recipient), 100e18);
        assertEq(reward.balanceOf(principal), 1);
        assertEq(distributor.owed(principal), 0);
    }

    function test_fixedOtherReceiverWithCorrectFloorFailsAndRollsBack() public {
        IShieldRegistryV1.ClaimRule memory bad = _claimRule(address(distributor));
        bad.ownerArgs = 1;
        bad.args = abi.encode(address(0), recipient);
        ClaimExecutorV1.Config memory c = _claimConfig();
        c.claims[0] = registry.listClaimRule(bad);
        distributor.setOwed(principal, 100e18);
        bytes32 id = _register(_claimParams(c));
        _reject(id, abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, address(reward)));
        _fire(id, 0, "");
        assertEq(distributor.owed(principal), 100e18);
        assertEq(reward.balanceOf(recipient), 0);
    }

    function test_boundaryPriorAuthorityOnUnmeasuredTokenStillRequiresVenueReview() public {
        IShieldRegistryV1.ClaimRule memory r = IShieldRegistryV1.ClaimRule(
            address(venue),
            venue.oldAuthority.selector,
            3,
            1,
            abi.encode(address(0), address(asset), recipient)
        );
        ClaimExecutorV1.Config memory c = _config();
        c.claims[0] = registry.listClaimRule(r);
        vm.prank(principal);
        asset.approve(address(venue), 10e18);
        uint256 before_ = asset.balanceOf(principal);
        bytes32 id = _register(_claimParams(c));
        _fire(id, 0, "");
        assertEq(asset.balanceOf(principal), before_ - 10e18);
        assertEq(asset.balanceOf(recipient), 10e18);
        assertEq(reward.balanceOf(principal), 100e18);
    }

    function test_noSandboxApprovalEvenWhenSandboxWasPrefunded() public {
        IShieldRegistryV1.ClaimRule memory r = IShieldRegistryV1.ClaimRule(
            address(venue), venue.sandboxPull.selector, 1, 1, abi.encode(address(0))
        );
        ClaimExecutorV1.Config memory c = _config();
        c.claims[0] = registry.listClaimRule(r);
        bytes32 id = _register(_claimParams(c));
        address clone = claims.nextClone(id);
        reward.mint(clone, 100e18);
        vm.expectRevert();
        _fire(id, 0, "");
        assertEq(reward.balanceOf(clone), 100e18);
        assertEq(reward.balanceOf(address(0xBAD)), 0);
        assertEq(reward.allowance(clone, address(venue)), 0);
    }

    function test_delistedRulesAndReadsSurviveUnchangedAmendmentButNotChangedConfig() public {
        ClaimExecutorV1.Config memory c = _config();
        IShieldV1.MandateParams memory p = _claimParams(c);
        bytes32 id = _register(p);
        registry.delistClaimRule(venueRule);
        registry.delistDescriptor(venueRead);
        p.validUntil += 1 days;
        vm.prank(principal);
        core.amendMandate(id, p);
        _fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 100e18);
        c.dust = 1;
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ClaimExecutorV1.ConfigInvalid.selector, "claim:rule"));
        core.amendMandate(id, p);
    }

    function test_newRuleAndDescriptorCannotReplaceExistingContentIds() public {
        ClaimExecutorV1.Config memory c = _config();
        bytes32 id = _register(_claimParams(c));
        IShieldRegistryV1.ClaimRule memory r = _claimRule(address(venue));
        r.selector = venue.collect.selector;
        r.ownerArgs = 1;
        r.args = abi.encode(address(0), recipient);
        bytes32 newId = registry.listClaimRule(r);
        assertTrue(newId != venueRule);
        registry.delistClaimRule(venueRule);
        registry.delistDescriptor(venueRead);
        _fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 100e18);
        assertEq(reward.balanceOf(recipient), 0);
    }

    function test_ruleRevocationRemainsEffectiveAfterUnchangedAmendment() public {
        IShieldV1.MandateParams memory p = _claimParams(_config());
        bytes32 id = _register(p);
        vm.prank(enforcer);
        registry.revokeClaimRule(venueRule);
        p.validUntil += 1;
        vm.prank(principal);
        core.amendMandate(id, p);
        _reject(id, abi.encodeWithSelector(ClaimExecutorV1.ClaimRuleRevoked.selector, venueRule));
        _fire(id, 0, "");
        assertEq(venue.calls(), 0);
    }

    function test_descriptorRevocationStopsLiveClaim() public {
        bytes32 id = _register(_claimParams(_config()));
        vm.prank(enforcer);
        registry.revokeDescriptor(venueRead);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked"));
        _fire(id, 0, "");
        assertEq(venue.calls(), 0);
    }

    function test_targetSuspensionCheckedEvenWhenReadUsesDifferentTarget() public {
        ClaimExecutorV1.Config memory c = _config();
        c.claimable[0] = _claimConfig().claimable[0];
        bytes32 id = _register(_claimParams(c));
        vm.prank(enforcer);
        registry.suspend(address(venue));
        _reject(id, abi.encodeWithSelector(ClaimExecutorV1.VenueBlocked.selector, address(venue)));
        _fire(id, 0, "");
        assertEq(venue.calls(), 0);
    }

    function testFuzz_allOwnerBitmapWordsAndFixedWords(uint16 bitmap) public {
        vm.assume(bitmap != 0);
        bytes memory blanks = new bytes(16 * 32);
        bytes memory expected = new bytes(16 * 32);
        for (uint256 i; i < 16; ++i) {
            bool ownerWord = (uint256(bitmap) >> i) & 1 != 0;
            uint256 fixedWord = 123 + i;
            uint256 original = ownerWord ? 0 : fixedWord;
            uint256 boundWord = ownerWord ? uint256(uint160(principal)) : fixedWord;
            assembly ("memory-safe") {
                mstore(add(add(blanks, 32), mul(i, 32)), original)
                mstore(add(add(expected, 32), mul(i, 32)), boundWord)
            }
        }
        bytes4 selector = bytes4(keccak256("reviewWords"));
        venue.expectCall(abi.encodePacked(selector, expected), principal);
        IShieldRegistryV1.ClaimRule memory r =
            IShieldRegistryV1.ClaimRule(address(venue), selector, 16, bitmap, blanks);
        ClaimExecutorV1.Config memory c = _config();
        c.claims[0] = registry.listClaimRule(r);
        bytes32 id = _register(_claimParams(c));
        _fire(id, 0, "");
        (IShieldRegistryV1.ClaimRule memory stored,,) = registry.claimRuleOf(c.claims[0]);
        assertEq(stored.args, blanks);
        assertEq(reward.balanceOf(principal), 100e18);
    }

    function testFuzz_recipeBindsAnyAdmittedSubjectPosition(uint8 rawIndex, uint8 rawCount, bool shape)
        public
    {
        uint8 index = uint8(bound(rawIndex, 0, 127));
        uint8 count = uint8(bound(rawCount, uint256(index) + 1, 255));
        ClaimsEchoRead echo = new ClaimsEchoRead();
        ClaimsRecipeHarness harness = new ClaimsRecipeHarness();
        IDescriptors.Descriptor memory d = _descriptor(bytes4(keccak256("echo")));
        d.kind = shape ? IDescriptors.DescriptorKind.Shape : IDescriptors.DescriptorKind.PerAddress;
        d.target = shape ? address(0) : address(echo);
        d.argCount = count;
        // forge-lint: disable-next-line(unsafe-typecast)
        d.subjectArg = int8(index);
        d.word = index;
        d.copyBytes = uint16((uint256(index) + 1) * 32);
        bytes32 desc = registry.listDescriptor(d);
        bytes memory args = new bytes(uint256(count) * 32);
        for (uint256 i; i < count; ++i) {
            uint256 value = i == index ? 0 : 7;
            assembly ("memory-safe") { mstore(add(add(args, 32), mul(i, 32)), value) }
        }
        ExprLib.Read memory r = ExprLib.Read(desc, address(echo), args, ExprLib.Subject.Principal, 0);
        ClaimExecutorV1.Config memory c = _config();
        c.claimable[0] = r;
        claims.validateConfig(claims.ACTION_CLAIM_COLLECT(), address(reward), abi.encode(uint8(1), c));
        assertEq(
            harness.read(r, principal, IDescriptors(address(registry))), int256(uint256(uint160(principal)))
        );
    }

    function test_coreStillAcceptsAndFiresSemanticsSixFromSeparatelyListedExecutor() public {
        ClaimsLegacyComposeProbe legacy = new ClaimsLegacyComposeProbe();
        registry.setExecutor(address(legacy), true);
        IShieldV1.MandateParams memory p = _claimParams(_config());
        p.executor = address(legacy);
        p.action = keccak256("claim.compose");
        bytes32 id = _register(p);
        assertEq(_fire(id, 0, ""), 0);
        assertEq(legacy.calls(), 1);
        assertEq(core.getMandate(id).firings, 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {ClaimsLegacyComposeProbe} from "./V1ClaimsConfirmation.t.sol";

contract R7SweepHook is MockToken {
    address public clone;
    address public recovery;
    IShieldV1 public core;
    bytes32 public id;
    bool public recovered;
    uint256 public firingsDuringTransfer;

    function arm(address c, address token, IShieldV1 s, bytes32 mandate) external {
        clone = c;
        recovery = token;
        core = s;
        id = mandate;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (msg.sender == clone) {
            address[] memory tokens = new address[](1);
            tokens[0] = recovery;
            DisposableCloneV1(clone).sendToOwner(tokens);
            recovered = true;
            firingsDuringTransfer = core.getMandate(id).firings;
        }
        return super.transfer(to, value);
    }
}

contract R7RecoveryVenue {
    MockToken public immutable reward;
    MockToken public immutable bonus;
    bool public earlyRecovery;
    bytes public earlyReason;
    uint256 public paid = 100e18;

    constructor(MockToken a, MockToken b) {
        reward = a;
        bonus = b;
    }

    function setPaid(uint256 v) external {
        paid = v;
    }

    function claimable(address) external pure returns (uint256) {
        return 100e18;
    }

    function collect(address) external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(bonus);
        (earlyRecovery, earlyReason) =
            msg.sender.call(abi.encodeCall(DisposableCloneV1.sendToOwner, (tokens)));
        bonus.mint(msg.sender, 7e18);
        reward.mint(msg.sender, paid);
    }
}

contract V1Round7RecoveryTest is V1ReviewBase {
    function _tokens(address a) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    function _fixture()
        internal
        returns (bytes32 id, address clone, R7RecoveryVenue venue, R7SweepHook hook)
    {
        hook = new R7SweepHook();
        venue = new R7RecoveryVenue(hook, output);
        ClaimExecutorV1.Config memory c = _claimConfig();
        c.claims[0] = registry.listClaimRule(
            IShieldRegistryV1.ClaimRule(address(venue), venue.collect.selector, 1, 1, abi.encode(address(0)))
        );
        c.rewardTokens[0] = address(hook);
        c.claimable[0].descriptor = registry.listDescriptor(_claimableDescriptor(address(venue)));
        c.claimable[0].target = address(venue);
        id = _register(_claimParams(c));
        clone = claims.nextClone(id);
        hook.arm(clone, address(output), IShieldV1(address(core)), id);
    }

    function test_freshCloneRejectsRecoveryZeroOwnerAndUnauthorizedRetirement() public {
        DisposableCloneV1 c = new DisposableCloneV1(address(this));
        address[] memory tokens = _tokens(address(output));
        vm.expectRevert(DisposableCloneV1.NotFinished.selector);
        c.sendToOwner(tokens);
        vm.expectRevert(DisposableCloneV1.NoOwner.selector);
        c.finish(tokens, address(0));
        vm.prank(recipient);
        vm.expectRevert(DisposableCloneV1.NotExecutor.selector);
        c.finish(tokens, recipient);
        assertEq(c.owner(), address(0));
    }

    function test_observationRecoveryBlockedInsideStepButRunsDuringFinishBeforeCoreSettlement() public {
        (bytes32 id, address clone, R7RecoveryVenue venue, R7SweepHook hook) = _fixture();
        _fire(id, 0, "");
        assertFalse(venue.earlyRecovery());
        assertEq(venue.earlyReason(), abi.encodeWithSelector(DisposableCloneV1.NotFinished.selector));
        assertTrue(hook.recovered(), "callback during finish already has recovery access");
        assertEq(hook.firingsDuringTransfer(), 0, "core has not settled yet");
        assertEq(core.getMandate(id).firings, 1);
        assertEq(output.balanceOf(principal), 7e18);
        assertEq(output.balanceOf(clone), 0);
        assertEq(DisposableCloneV1(clone).owner(), principal);
    }

    function test_failedFiringRollsBackEarlyRecoveryAndOwnerRecord() public {
        (bytes32 id, address clone, R7RecoveryVenue venue, R7SweepHook hook) = _fixture();
        venue.setPaid(90e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(ClaimExecutorV1.BelowClaimable.selector, address(hook), 90e18, 100e18)
            )
        );
        _fire(id, 0, "");
        assertEq(clone.code.length, 0);
        assertEq(output.balanceOf(principal), 0);
        assertEq(hook.balanceOf(principal), 0);
        assertFalse(hook.recovered());
        assertEq(claims.firings(id), 0);
    }

    function test_anyCallerAndDuplicateEntriesStillPayOnlyImmutableOwner() public {
        DisposableCloneV1 c = new DisposableCloneV1(address(this));
        c.finish(new address[](0), principal);
        output.mint(address(c), 7e18);
        address[] memory tokens = new address[](2);
        tokens[0] = address(output);
        tokens[1] = address(output);
        vm.prank(recipient);
        c.sendToOwner(tokens);
        c.sendToOwner(tokens);
        assertEq(output.balanceOf(principal), 7e18);
        assertEq(output.balanceOf(recipient), 0);
        vm.expectRevert(DisposableCloneV1.AlreadyUsed.selector);
        c.finish(tokens, recipient);
        IExecutorV1.Call memory call_;
        vm.expectRevert(DisposableCloneV1.AlreadyUsed.selector);
        c.step(call_);
    }

    function test_oldCloneRecoveryCannotConsumeNextFiringPrefundsOrChangeAccounting() public {
        (bytes32 id, address first,, R7SweepHook hook) = _fixture();
        _fire(id, 0, "");
        address second = claims.nextClone(id);
        assertNotEq(first, second);
        output.mint(first, 11e18);
        output.mint(second, 13e18);
        vm.prank(recipient);
        DisposableCloneV1(first).sendToOwner(_tokens(address(output)));
        assertEq(output.balanceOf(second), 13e18);
        assertEq(claims.nextClone(id), second);
        hook.arm(second, address(output), IShieldV1(address(core)), id);
        _fire(id, 0, "");
        assertEq(output.balanceOf(principal), 38e18);
        assertEq(core.getMandate(id).firings, 2);
        assertEq(core.getMandate(id).cumulativeUsed, 0);
        assertEq(DisposableCloneV1(first).owner(), principal);
        assertEq(DisposableCloneV1(second).owner(), principal);
    }

    function test_badTokenOnlyRevertsItsChosenRecoveryBatch() public {
        DisposableCloneV1 c = new DisposableCloneV1(address(this));
        c.finish(new address[](0), principal);
        output.mint(address(c), 3e18);
        address[] memory tokens = new address[](2);
        tokens[0] = address(output);
        tokens[1] = address(0xBAD);
        vm.expectRevert();
        c.sendToOwner(tokens);
        assertEq(output.balanceOf(address(c)), 3e18);
        c.sendToOwner(_tokens(address(output)));
        assertEq(output.balanceOf(principal), 3e18);
    }

    function test_composeRequiresNewListingAndCannotReplaceLiveExecutor() public {
        ClaimsLegacyComposeProbe probe = new ClaimsLegacyComposeProbe();
        IShieldV1.MandateParams memory p = _claimParams(_claimConfig());
        bytes32 existing = _register(p);
        p.executor = address(probe);
        p.action = keccak256("claim.compose");
        vm.prank(principal);
        vm.expectRevert();
        core.registerMandate(p);
        registry.setExecutor(address(probe), true);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.FieldImmutable.selector, bytes32("executor")));
        core.amendMandate(existing, p);
        bytes32 fresh = _register(p);
        assertEq(_fire(fresh, 0, ""), 0);
        assertEq(probe.calls(), 1);
        assertEq(core.getMandate(existing).executor, address(claims));
    }
}

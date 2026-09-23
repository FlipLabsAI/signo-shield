// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockExecutor, MockToken, MockWallet1271} from "./mocks/MockExecutor.sol";
import {MockBalances} from "./mocks/MockCatalog.sol";

contract ShieldV1Test is Test {
    ShieldV1 internal shield;
    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    MockExecutor internal exec;
    MockToken internal usdc;
    MockBalances internal gauge; // an external read target for triggers

    address internal admin = address(0xAD);
    address internal enforcer = address(0xE0);
    address internal feeSink = address(0xFEE);
    uint256 internal principalKey = 0xA11CE;
    address internal principal;
    address internal agent = address(0xA6E);

    bytes32 internal dBalance;
    bytes32 internal constant ACTION = keccak256("mock.transform");
    bytes32 internal constant CLAIM = keccak256("mock.claim");

    function setUp() public {
        principal = vm.addr(principalKey);
        registry = new ShieldRegistryV1(admin);
        shield = new ShieldV1(registry, 10); // 10 bps
        ev = new ExpressionEvaluator(registry);
        exec = new MockExecutor(address(shield));
        usdc = new MockToken();
        gauge = new MockBalances();
        vm.startPrank(admin);
        registry.setEnforcer(enforcer, true);
        registry.setExecutor(address(exec), true);
        registry.setEvaluator(address(ev), true);
        shield.setFeeRecipient(feeSink);
        dBalance = registry.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.Shape,
                target: address(0),
                selector: bytes4(keccak256("balanceOf(address)")),
                argCount: 1,
                subjectArg: 0,
                subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
                word: 0,
                isSigned: false,
                mustBePositive: false,
                decimals: 0,
                freshness: IDescriptors.Freshness.None,
                maxAge: 0,
                gasStipend: 100_000,
                copyBytes: 32,
                unboundedTop: false
            })
        );
        vm.stopPrank();
        usdc.mint(principal, 1_000_000e6);
        vm.prank(principal);
        usdc.approve(address(shield), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _tree(address target, address who, ExprLib.Kind cmp, uint256 threshold)
        internal
        view
        returns (bytes memory)
    {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dBalance,
            target: target,
            args: abi.encode(who),
            subject: ExprLib.Subject.Principal,
            decimals: target == address(usdc) ? 18 : 6 // pinned to the instance (MockToken 18, MockBalances 6)
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: threshold, b: 0});
        n[2] = ExprLib.Node({kind: uint8(cmp), a: 0, b: 1});
        return abi.encode(r, n);
    }

    function _params() internal view returns (IShieldV1.MandateParams memory p) {
        p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(exec),
            evaluator: address(ev),
            asset: address(usdc),
            maxTransactionValue: 1_000e6,
            maxCumulativeValue: 10_000e6,
            // forge-lint: disable-next-line(environment-read-across-mutation)
            validFrom: uint48(block.timestamp),
            // forge-lint: disable-next-line(environment-read-across-mutation)
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 50,
            funding: uint8(IShieldV1.FundingMode.PULL),
            action: ACTION,
            actionConfig: "",
            trigger: "",
            outcome: ""
        });
    }

    function _register(IShieldV1.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    // ----------------------------------------------------------- registration

    function test_registerStampsFeeAndRefusesAboveMax() public {
        IShieldV1.MandateParams memory p = _params();
        p.maxFeeBps = 5; // below the current 10
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.FeeAboveMax.selector, 10, 5));
        shield.registerMandate(p);
        p.maxFeeBps = 10;
        bytes32 id = _register(p);
        IShieldV1.Mandate memory m = shield.getMandate(id);
        assertEq(m.feeBps, 10);
        assertEq(m.revision, 1);
        // The global rate rising afterwards does not touch it.
        vm.prank(admin);
        shield.setFeeBps(100);
        assertEq(shield.getMandate(id).feeBps, 10);
    }

    function test_registerRefusesUnlistedAndBadConfig() public {
        IShieldV1.MandateParams memory p = _params();
        p.executor = address(0x1234);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.ExecutorNotListed.selector, address(0x1234)));
        shield.registerMandate(p);
        p = _params();
        p.action = keccak256("nope");
        vm.prank(principal);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldV1.ActionNotSupported.selector, address(exec), p.action)
        );
        shield.registerMandate(p);
        p = _params();
        p.actionConfig = hex"ff";
        vm.prank(principal);
        vm.expectRevert("bad config");
        shield.registerMandate(p);
    }

    function test_registerValidatesTreesAndCapturesBaselines() public {
        gauge.set(principal, 500);
        IShieldV1.MandateParams memory p = _params();
        // trigger: gauge balance(principal) > 400; outcome uses SIGNED so a baseline is captured
        p.trigger = _tree(address(gauge), principal, ExprLib.Kind.GT, 400);
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dBalance,
            target: address(gauge),
            args: abi.encode(principal),
            subject: ExprLib.Subject.Principal,
            decimals: 6
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.SIGNED), a: 0, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.GE), a: 0, b: 1});
        p.outcome = abi.encode(r, n);
        bytes32 id = _register(p);
        IShieldV1.Mandate memory m = shield.getMandate(id);
        assertEq(m.outcomeSigned.length, 1);
        assertEq(m.outcomeSigned[0], int256(500));
        // a tree naming a stranger under a principal-required descriptor is refused at signing
        p.trigger = _tree(address(gauge), address(0xBAD), ExprLib.Kind.GT, 0);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        shield.registerMandate(p);
    }

    // ------------------------------------------------------------------ firing

    function test_fireSpendsChargesFeeAndRecords() public {
        bytes32 id = _register(_params());
        uint256 before = usdc.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e6, "");
        // spent 100 plus a 10 bps fee
        assertEq(spent, 100e6 + 0.1e6);
        assertEq(before - usdc.balanceOf(principal), 100e6 + 0.1e6);
        assertEq(usdc.balanceOf(feeSink), 0.1e6);
        IShieldV1.Mandate memory m = shield.getMandate(id);
        assertEq(m.cumulativeUsed, 100e6 + 0.1e6);
        assertEq(m.firings, 1);
        assertEq(m.lastFiredAt, uint48(block.timestamp));
    }

    function test_fireUnspentIsRefundedAndOnlySpentIsCharged() public {
        bytes32 id = _register(_params());
        exec.setSpendBps(4000); // spends 40, returns 60
        uint256 before = usdc.balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e6, "");
        assertEq(spent, 40e6 + 0.04e6);
        assertEq(before - usdc.balanceOf(principal), 40e6 + 0.04e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 40e6 + 0.04e6);
    }

    function test_spendRuleRevertsOnExcessMeasurementAndExcessReport() public {
        bytes32 id = _register(_params());
        // the executor pulls 1 extra unit from the principal through a prior approval
        vm.prank(principal);
        usdc.approve(address(exec), type(uint256).max);
        exec.setExtraPull(1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.SpendExceedsAmount.selector, 100e6 + 1, 100e6));
        shield.fire(id, 100e6, "");
        exec.setExtraPull(0);
        exec.setReport(true, 100e6 + 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.SpendExceedsAmount.selector, 100e6 + 1, 100e6));
        shield.fire(id, 100e6, "");
        // under-report: the measurement wins
        exec.setReport(true, 1);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 100e6, "");
        assertEq(spent, 100e6 + 0.1e6);
    }

    function test_fireRevertsWhenExecutorRevertsAndRollsBack() public {
        bytes32 id = _register(_params());
        exec.setRevert(true);
        uint256 before = usdc.balanceOf(principal);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e6, "");
        assertEq(usdc.balanceOf(principal), before);
        assertEq(shield.getMandate(id).cumulativeUsed, 0);
    }

    function test_triggerAndOutcomeGateTheFiring() public {
        gauge.set(principal, 100);
        IShieldV1.MandateParams memory p = _params();
        p.trigger = _tree(address(gauge), principal, ExprLib.Kind.GT, 150);
        bytes32 id = _register(p);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.TRIGGER_NOT_MET
            )
        );
        shield.fire(id, 100e6, "");
        gauge.set(principal, 200);
        vm.prank(agent);
        shield.fire(id, 100e6, "");

        // outcome on the final state: the owner's usdc must be at least before - amount (it is), then fails when set impossibly
        p = _params();
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dBalance,
            target: address(usdc),
            args: abi.encode(principal),
            subject: ExprLib.Subject.Principal,
            decimals: 18
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](5);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.BEFORE), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.SUB), a: 0, b: 1}); // what left, fee included
        n[3] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: 50e6, b: 0});
        n[4] = ExprLib.Node({kind: uint8(ExprLib.Kind.LE), a: 2, b: 3}); // at most 50 left the owner
        p.outcome = abi.encode(r, n);
        bytes32 id2 = _register(p);
        exec.setSpendBps(4000); // 40 spent + fee, passes
        vm.prank(agent);
        shield.fire(id2, 100e6, "");
        exec.setSpendBps(10_000); // 100 spent, fails on the final state and rolls back
        uint256 before = usdc.balanceOf(principal);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id2, IShieldV1.MandateReason.OUTCOME_FAILED, ""
            )
        );
        shield.fire(id2, 100e6, "");
        assertEq(usdc.balanceOf(principal), before);
    }

    function test_fundingNoneNothingMayLeave() public {
        IShieldV1.MandateParams memory p = _params();
        p.funding = uint8(IShieldV1.FundingMode.NONE);
        p.action = CLAIM;
        p.maxTransactionValue = 0;
        p.maxCumulativeValue = 0;
        bytes32 id = _register(p);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.AMOUNT_NOT_ZERO
            )
        );
        shield.fire(id, 1, "");
        vm.prank(agent);
        uint256 spent = shield.fire(id, 0, "");
        assertEq(spent, 0);
        // an executor that pulls anyway is caught
        vm.prank(principal);
        usdc.approve(address(exec), type(uint256).max);
        exec.setExtraPull(5);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.NothingMayLeave.selector, 5));
        shield.fire(id, 0, "");
    }

    function test_failedAttemptLeavesNoBookkeeping() public {
        bytes32 id = _register(_params());
        vm.prank(agent);
        shield.fire(id, 10e6, "");
        IShieldV1.Mandate memory before = shield.getMandate(id);
        exec.setRevert(true);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 10e6, ""); // a failed attempt
        exec.setRevert(false);
        IShieldV1.Mandate memory afterFail = shield.getMandate(id);
        assertEq(afterFail.firings, before.firings);
        assertEq(afterFail.lastFiredAt, before.lastFiredAt);
        assertEq(afterFail.cumulativeUsed, before.cumulativeUsed);
        vm.prank(agent);
        shield.fire(id, 10e6, ""); // still allowed: the failure consumed nothing
    }

    // --------------------------------------------------------------- amendment

    function test_amendKeepsFeeBudgetAndBaselinesRules() public {
        gauge.set(principal, 500);
        IShieldV1.MandateParams memory p = _params();
        p.trigger = _tree(address(gauge), principal, ExprLib.Kind.GT, 400);
        bytes32 id = _register(p);
        vm.prank(agent);
        shield.fire(id, 100e6, "");
        // the stamped fee (10) must fit the new ceiling
        p.maxFeeBps = 5;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.FeeAboveMax.selector, 10, 5));
        shield.amendMandate(id, p);
        // immutable fields
        p.maxFeeBps = 50;
        p.asset = address(gauge);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.FieldImmutable.selector, bytes32("asset")));
        shield.amendMandate(id, p);
        // budget cannot be moved under what was used
        p = _params();
        p.trigger = _tree(address(gauge), principal, ExprLib.Kind.GT, 400);
        p.maxCumulativeValue = 1e6;
        vm.prank(principal);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldV1.InvalidParams.selector, bytes32("maxCumulativeValue"))
        );
        shield.amendMandate(id, p);
        // a valid amendment keeps cumulativeUsed and bumps the revision
        p.maxCumulativeValue = 20_000e6;
        vm.prank(principal);
        shield.amendMandate(id, p);
        IShieldV1.Mandate memory m = shield.getMandate(id);
        assertEq(m.revision, 2);
        assertEq(m.cumulativeUsed, 100e6 + 0.1e6);
        assertEq(m.maxCumulativeValue, 20_000e6);
        // only the principal
        vm.prank(agent);
        vm.expectRevert(IShieldV1.NotPrincipal.selector);
        shield.amendMandate(id, p);
    }

    // -------------------------------------------------------------- revocation

    function _revokeDigest(bytes32 id, address who, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Revoke(bytes32 mandateId,address principal,uint256 nonce,uint256 deadline)"),
                id,
                who,
                nonce,
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SignoShield"),
                keccak256("1"),
                block.chainid,
                address(shield)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_revokeWithSigEOA() public {
        bytes32 id = _register(_params());
        // forge-lint: disable-next-line(environment-read-across-mutation)
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _revokeDigest(id, principal, 0, deadline);
        vm.expectRevert(IShieldV1.BadSignature.selector);
        shield.revokeWithSig(id, deadline, _sig(0xB0B, digest));
        vm.warp(deadline + 1);
        vm.expectRevert(IShieldV1.SignatureExpired.selector);
        shield.revokeWithSig(id, deadline, _sig(principalKey, digest));
        vm.warp(deadline - 10);
        vm.prank(address(0xCAFE)); // anyone may submit a valid signature
        shield.revokeWithSig(id, deadline, _sig(principalKey, digest));
        assertTrue(shield.getMandate(id).revoked);
        vm.expectRevert(); // replay: the nonce moved and the mandate is revoked
        shield.revokeWithSig(id, deadline, _sig(principalKey, digest));
    }

    function test_revokeWithSigContractWallet() public {
        uint256 ownerKey = 0xC0FFEE;
        MockWallet1271 wallet = new MockWallet1271(vm.addr(ownerKey));
        usdc.mint(address(wallet), 10_000e6);
        vm.prank(address(wallet));
        usdc.approve(address(shield), type(uint256).max);
        vm.prank(address(wallet));
        bytes32 wid = shield.registerMandate(_params());
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _revokeDigest(wid, address(wallet), 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        shield.revokeWithSig(wid, deadline, abi.encode(v, r, s));
        assertTrue(shield.getMandate(wid).revoked);
    }

    // -------------------------------------------------- halts and suspensions

    function test_haltEpochsQueuedRestorationAndDelay() public {
        bytes32 id = _register(_params());
        vm.prank(enforcer);
        registry.halt(address(exec));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.EXECUTOR_HALTED
            )
        );
        shield.fire(id, 10e6, "");
        // admin cannot restore without a queued approval
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.EpochMismatch.selector, address(exec), uint64(1))
        );
        registry.executeUnhalt(address(exec), 1);
        vm.prank(enforcer);
        registry.queueUnhalt(address(exec), 1);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.RestoreNotReady.selector, address(exec), uint64(1))
        );
        registry.executeUnhalt(address(exec), 1);
        // a new halt bumps the epoch and cancels the queue
        vm.prank(enforcer);
        registry.halt(address(exec));
        // forge-lint: disable-next-line(environment-read-across-mutation)
        vm.warp(block.timestamp + 25 hours);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.EpochMismatch.selector, address(exec), uint64(1))
        );
        registry.executeUnhalt(address(exec), 1);
        vm.prank(enforcer);
        registry.queueUnhalt(address(exec), 2);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(admin);
        registry.executeUnhalt(address(exec), 2);
        assertFalse(registry.isHalted(address(exec)));
        vm.prank(agent);
        shield.fire(id, 10e6, "");
    }

    function test_suspensionAndPermanentRevocation() public {
        address venue = address(0x5E);
        vm.prank(enforcer);
        registry.suspend(venue);
        assertTrue(registry.isVenueBlocked(venue));
        vm.prank(enforcer);
        registry.queueLift(venue, 1);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(admin);
        registry.executeLift(venue, 1);
        assertFalse(registry.isVenueBlocked(venue));
        vm.prank(enforcer);
        registry.revoke(venue);
        assertTrue(registry.isVenueBlocked(venue));
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IShieldRegistryV1.TargetRevoked.selector, venue));
        registry.suspend(venue);
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IShieldRegistryV1.TargetRevoked.selector, venue));
        registry.queueLift(venue, 1);
    }

    function test_descriptorRevocationStopsFiringsThatReadIt() public {
        gauge.set(principal, 500);
        IShieldV1.MandateParams memory p = _params();
        p.trigger = _tree(address(gauge), principal, ExprLib.Kind.GT, 400);
        bytes32 id = _register(p);
        vm.prank(enforcer);
        registry.revokeDescriptor(dBalance);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked"));
        shield.fire(id, 10e6, "");
        // and cannot be re-listed under the same id
        vm.prank(admin);
        vm.expectRevert();
        registry.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.Shape,
                target: address(0),
                selector: bytes4(keccak256("balanceOf(address)")),
                argCount: 1,
                subjectArg: 0,
                subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
                word: 0,
                isSigned: false,
                mustBePositive: false,
                decimals: 0,
                freshness: IDescriptors.Freshness.None,
                maxAge: 0,
                gasStipend: 100_000,
                copyBytes: 32,
                unboundedTop: false
            })
        );
    }

    /// Round 8: only an unsigned read's top can mean "unbounded"; a signed value
    /// cannot be above the int256 range, so the flag there is refused as meaningless.
    function test_unboundedTopOnlyOnUnsignedDescriptors() public {
        IDescriptors.Descriptor memory d = IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.Shape,
            target: address(0),
            selector: bytes4(keccak256("value(address)")),
            argCount: 1,
            subjectArg: 0,
            subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
            word: 0,
            isSigned: true,
            mustBePositive: false,
            decimals: 0,
            freshness: IDescriptors.Freshness.None,
            maxAge: 0,
            gasStipend: 100_000,
            copyBytes: 32,
            unboundedTop: true
        });
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IShieldRegistryV1.InvalidParams.selector, bytes32("unboundedTop"))
        );
        registry.listDescriptor(d);
        d.isSigned = false;
        vm.prank(admin);
        registry.listDescriptor(d);
    }

    function test_rolesAdminCannotBeEnforcerAndListingGatesNewOnly() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.AdminCannotBeEnforcer.selector, admin));
        registry.setEnforcer(admin, true);
        bytes32 id = _register(_params());
        vm.prank(admin);
        registry.setExecutor(address(exec), false); // delisted: live mandate keeps firing
        vm.prank(agent);
        shield.fire(id, 10e6, "");
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.ExecutorNotListed.selector, address(exec)));
        shield.registerMandate(_params());
    }
}

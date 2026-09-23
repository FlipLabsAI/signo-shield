// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {MockCatalog, MockBalances, MockFeed, MockNasty} from "./mocks/MockCatalog.sol";

contract ExpressionEvaluatorTest is Test {
    MockCatalog internal catalog;
    ExpressionEvaluator internal ev;
    MockBalances internal usdc;
    MockFeed internal feed;
    MockNasty internal nasty;
    address internal principal = address(0xA11CE);
    address internal stranger = address(0xBAD);

    bytes32 internal dBalance; // Shape: balanceOf(address), PrincipalRequired
    bytes32 internal dFeed; // PerAddress: latestRoundData, ChainlinkRound, signed, positive
    bytes32 internal dNasty; // PerAddress: value(), unsigned
    bytes32 internal dExplicitOk; // Shape balanceOf without subject rule

    function setUp() public {
        catalog = new MockCatalog();
        ev = new ExpressionEvaluator(catalog);
        usdc = new MockBalances();
        feed = new MockFeed();
        nasty = new MockNasty();
        dBalance = catalog.list(
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
                copyBytes: 32
            })
        );
        dFeed = catalog.list(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.PerAddress,
                target: address(feed),
                selector: MockFeed.latestRoundData.selector,
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
            })
        );
        dNasty = catalog.list(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.PerAddress,
                target: address(nasty),
                selector: MockNasty.value.selector,
                argCount: 0,
                subjectArg: -1,
                subjectRule: IDescriptors.SubjectRule.None,
                word: 0,
                isSigned: false,
                mustBePositive: false,
                decimals: 18,
                freshness: IDescriptors.Freshness.None,
                maxAge: 0,
                gasStipend: 100_000,
                copyBytes: 32
            })
        );
        feed.set(10, 2743e8, block.timestamp, 10);
        usdc.set(principal, 1000e6);
        usdc.set(stranger, 5e6);
    }

    // ------------------------------------------------------------ helpers

    function _read(bytes32 d, address target, bytes memory args, ExprLib.Subject s)
        internal
        pure
        returns (ExprLib.Read memory)
    {
        return ExprLib.Read({descriptor: d, target: target, args: args, subject: s, decimals: 6});
    }

    function _node(ExprLib.Kind k, uint256 a, uint256 b) internal pure returns (ExprLib.Node memory) {
        return ExprLib.Node({kind: uint8(k), a: a, b: b});
    }

    function _enc(ExprLib.Read[] memory r, ExprLib.Node[] memory n) internal pure returns (bytes memory) {
        return abi.encode(r, n);
    }

    /// balance(principal) > 500e6
    function _balanceAbove(uint256 threshold, address who, ExprLib.Subject s)
        internal
        view
        returns (bytes memory)
    {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dBalance, address(usdc), abi.encode(who), s);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.READ, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, threshold, 0);
        n[2] = _node(ExprLib.Kind.GT, 0, 1);
        return _enc(r, n);
    }

    // -------------------------------------------------------------- shape

    function test_validateAcceptsOwnerReadAndJudges() public view {
        bytes memory t = _balanceAbove(500e6, principal, ExprLib.Subject.Principal);
        ev.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
        assertTrue(ev.judgeTrigger(t, principal, new int256[](0), 0));
        bytes memory t2 = _balanceAbove(2000e6, principal, ExprLib.Subject.Principal);
        assertFalse(ev.judgeTrigger(t2, principal, new int256[](0), 0));
    }

    function test_principalBindingRejectsStrangerArgument() public {
        bytes memory t = _balanceAbove(1, stranger, ExprLib.Subject.Principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        ev.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
    }

    function test_principalRequiredRefusesNoSubject() public {
        bytes memory t = _balanceAbove(1, principal, ExprLib.Subject.None);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "subject"));
        ev.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
    }

    function test_explicitOtherAccountIsAllowedWhenChosen() public view {
        bytes memory t = _balanceAbove(1, stranger, ExprLib.Subject.Explicit);
        ev.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
        assertTrue(ev.judgeTrigger(t, principal, new int256[](0), 0));
    }

    function test_appendedPrincipalTrickIsRejectedByArgCount() public {
        // balanceOf(stranger) || principal: two words for a one-argument descriptor.
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dBalance, address(usdc), abi.encode(stranger, principal), ExprLib.Subject.Principal);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.READ, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, 1, 0);
        n[2] = _node(ExprLib.Kind.GT, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "args"));
        ev.validate(_enc(r, n), IEvaluatorV1.Phase.Trigger, principal, true);
    }

    function test_beforeIsRefusedInTrigger() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dBalance, address(usdc), abi.encode(principal), ExprLib.Subject.Principal);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.BEFORE, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, 1, 0);
        n[2] = _node(ExprLib.Kind.GT, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "beforeInTrigger"));
        ev.validate(_enc(r, n), IEvaluatorV1.Phase.Trigger, principal, true);
        // and accepted in the outcome
        ev.validate(_enc(r, n), IEvaluatorV1.Phase.Outcome, principal, true);
    }

    function test_numericRootAndBoolMisuseAreRefused() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](0);
        ExprLib.Node[] memory n = new ExprLib.Node[](1);
        n[0] = _node(ExprLib.Kind.CONST, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "root"));
        ev.validate(_enc(r, n), IEvaluatorV1.Phase.Trigger, principal, true);

        ExprLib.Node[] memory m = new ExprLib.Node[](3);
        m[0] = _node(ExprLib.Kind.CONST, 1, 0);
        m[1] = _node(ExprLib.Kind.CONST, 2, 0);
        m[2] = _node(ExprLib.Kind.AND, 0, 1); // AND over numbers
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "boolOperand"));
        ev.validate(_enc(r, m), IEvaluatorV1.Phase.Trigger, principal, true);

        ExprLib.Node[] memory q = new ExprLib.Node[](4);
        q[0] = _node(ExprLib.Kind.CONST, 1, 0);
        q[1] = _node(ExprLib.Kind.CONST, 2, 0);
        q[2] = _node(ExprLib.Kind.LT, 0, 1);
        q[3] = _node(ExprLib.Kind.ADD, 2, 0); // arithmetic over a Boolean
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "numOperand"));
        ev.validate(_enc(r, q), IEvaluatorV1.Phase.Trigger, principal, true);
    }

    function test_forwardReferenceIsRefused() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](0);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.CONST, 1, 0);
        n[1] = _node(ExprLib.Kind.LT, 0, 2); // refers forward
        n[2] = _node(ExprLib.Kind.CONST, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "numOperand"));
        ev.validate(_enc(r, n), IEvaluatorV1.Phase.Trigger, principal, true);
    }

    // -------------------------------------------------------------- reads

    function test_chainlinkFreshnessAndPositivity() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dFeed, address(feed), "", ExprLib.Subject.None);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.READ, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, 2000e8, 0);
        n[2] = _node(ExprLib.Kind.GT, 0, 1);
        bytes memory t = _enc(r, n);
        assertTrue(ev.judgeTrigger(t, principal, new int256[](0), 0));

        // forge-lint: disable-next-line(environment-read-across-mutation)
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        ev.judgeTrigger(t, principal, new int256[](0), 0);

        feed.set(11, 2743e8, block.timestamp, 10); // answeredInRound < roundId
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        ev.judgeTrigger(t, principal, new int256[](0), 0);

        feed.set(11, 0, block.timestamp, 11);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadNotPositive.selector, 0));
        ev.judgeTrigger(t, principal, new int256[](0), 0);

        feed.set(11, -5, block.timestamp, 11);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadNotPositive.selector, 0));
        ev.judgeTrigger(t, principal, new int256[](0), 0);
    }

    /// Round 7: an unsigned value above the int256 range (Aave's "no debt" health factor)
    /// counts as the top of the range: never negative, above every limit.
    function test_unsignedAboveIntMaxSaturatesNeverNegative() public view {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dNasty, address(nasty), "", ExprLib.Subject.None);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.READ, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, 0, 0);
        n[2] = _node(ExprLib.Kind.LT, 0, 1); // would be true if max were cast to -1
        assertFalse(ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0));
        n[1] = _node(ExprLib.Kind.CONST, 15e17, 0);
        n[2] = _node(ExprLib.Kind.GT, 0, 1); // "health factor above 1.5" holds with no debt
        assertTrue(ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0));
    }

    function test_shortReturnAndGasExhaustionRevert() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dNasty, address(nasty), "", ExprLib.Subject.None);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = _node(ExprLib.Kind.READ, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, 0, 0);
        n[2] = _node(ExprLib.Kind.GT, 0, 1);
        nasty.setShort(true);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadTooShort.selector, 0, 16, 32));
        ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0);
        nasty.setShort(false);
        nasty.setBurn(true);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadFailed.selector, 0, ""));
        ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0);
    }

    // ---------------------------------------------------------- arithmetic

    function test_divByZeroAndOverflowRevertNeverFalse() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](0);
        ExprLib.Node[] memory n = new ExprLib.Node[](4);
        n[0] = _node(ExprLib.Kind.CONST, 1, 0);
        n[1] = _node(ExprLib.Kind.CONST, 0, 0);
        n[2] = _node(ExprLib.Kind.DIV, 0, 1);
        n[3] = _node(ExprLib.Kind.GT, 2, 1);
        vm.expectRevert(); // panic: division by zero
        ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0);

        ExprLib.Node[] memory m = new ExprLib.Node[](4);
        m[0] = _node(ExprLib.Kind.CONST, uint256(type(int256).max), 0);
        m[1] = _node(ExprLib.Kind.CONST, 2, 0);
        m[2] = _node(ExprLib.Kind.MUL, 0, 1);
        m[3] = _node(ExprLib.Kind.GT, 2, 1);
        vm.expectRevert(); // panic: overflow
        ev.judgeTrigger(_enc(r, m), principal, new int256[](0), 0);
    }

    function test_negativeConstantsAndSubtraction() public view {
        ExprLib.Read[] memory r = new ExprLib.Read[](0);
        ExprLib.Node[] memory n = new ExprLib.Node[](4);
        n[0] = _node(ExprLib.Kind.CONST, uint256(int256(-5)), 0);
        n[1] = _node(ExprLib.Kind.CONST, 3, 0);
        n[2] = _node(ExprLib.Kind.SUB, 0, 1); // -8
        n[3] = _node(ExprLib.Kind.LT, 2, 1);
        assertTrue(ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0));
    }

    // ------------------------------------------------------ signed / before

    function test_repayExampleTriggerAndOutcome() public {
        // trigger: balance(principal) < 1500e6 ; outcome: balance now >= 2000e6 AND (before - now) <= amount
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dBalance, address(usdc), abi.encode(principal), ExprLib.Subject.Principal);
        ExprLib.Node[] memory tn = new ExprLib.Node[](3);
        tn[0] = _node(ExprLib.Kind.READ, 0, 0);
        tn[1] = _node(ExprLib.Kind.CONST, 1500e6, 0);
        tn[2] = _node(ExprLib.Kind.LT, 0, 1);
        bytes memory trigger = _enc(r, tn);
        assertTrue(ev.judgeTrigger(trigger, principal, new int256[](0), 0)); // 1000 < 1500

        ExprLib.Node[] memory on = new ExprLib.Node[](8);
        on[0] = _node(ExprLib.Kind.READ, 0, 0); // now
        on[1] = _node(ExprLib.Kind.CONST, 900e6, 0);
        on[2] = _node(ExprLib.Kind.GE, 0, 1); // now >= 900
        on[3] = _node(ExprLib.Kind.BEFORE, 0, 0);
        on[4] = _node(ExprLib.Kind.SUB, 3, 0); // before - now
        on[5] = _node(ExprLib.Kind.AMOUNT, 0, 0);
        on[6] = _node(ExprLib.Kind.LE, 4, 5); // spent <= amount
        on[7] = _node(ExprLib.Kind.AND, 2, 6);
        bytes memory outcome = _enc(r, on);
        ev.validate(outcome, IEvaluatorV1.Phase.Outcome, principal, true);
        int256[] memory before = ev.snapshot(outcome, principal); // 1000e6
        assertEq(before[0], int256(1000e6));
        usdc.set(principal, 950e6); // 50 left the owner
        assertTrue(ev.judgeOutcome(outcome, principal, new int256[](0), before, 50e6));
        assertFalse(ev.judgeOutcome(outcome, principal, new int256[](0), before, 40e6)); // spent 50 > amount 40
        usdc.set(principal, 800e6);
        assertFalse(ev.judgeOutcome(outcome, principal, new int256[](0), before, 500e6)); // below 900
    }

    function test_signedBaselineMovedSinceSigning() public {
        // moved 10% since signing: now * 100 < signed * 90
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = _read(dFeed, address(feed), "", ExprLib.Subject.None);
        ExprLib.Node[] memory n = new ExprLib.Node[](7);
        n[0] = _node(ExprLib.Kind.READ, 0, 0);
        n[1] = _node(ExprLib.Kind.CONST, 100, 0);
        n[2] = _node(ExprLib.Kind.MUL, 0, 1);
        n[3] = _node(ExprLib.Kind.SIGNED, 0, 0);
        n[4] = _node(ExprLib.Kind.CONST, 90, 0);
        n[5] = _node(ExprLib.Kind.MUL, 3, 4);
        n[6] = _node(ExprLib.Kind.LT, 2, 5);
        bytes memory t = _enc(r, n);
        int256[] memory signedVals = ev.capture(t, principal);
        assertEq(signedVals[0], int256(2743e8));
        assertFalse(ev.judgeTrigger(t, principal, signedVals, 0));
        feed.set(12, 2400e8, block.timestamp, 12); // fell 12.5%
        assertTrue(ev.judgeTrigger(t, principal, signedVals, 0));
    }

    // --------------------------------------------------------------- limits

    function test_sharedNodesEvaluateOncePerNode() public view {
        // A 12-node graph where every node references the previous two: exponential if recursive.
        ExprLib.Read[] memory r = new ExprLib.Read[](0);
        ExprLib.Node[] memory n = new ExprLib.Node[](14);
        n[0] = _node(ExprLib.Kind.CONST, 1, 0);
        n[1] = _node(ExprLib.Kind.CONST, 1, 0);
        for (uint256 i = 2; i < 12; i++) {
            n[i] = _node(ExprLib.Kind.ADD, i - 1, i - 2);
        }
        n[12] = _node(ExprLib.Kind.CONST, 0, 0);
        n[13] = _node(ExprLib.Kind.GT, 11, 12);
        uint256 g0 = gasleft();
        assertTrue(ev.judgeTrigger(_enc(r, n), principal, new int256[](0), 0));
        assertLt(g0 - gasleft(), 200_000);
    }

    function test_treeLimits() public {
        ExprLib.Read[] memory r = new ExprLib.Read[](0);
        ExprLib.Node[] memory n = new ExprLib.Node[](65);
        for (uint256 i = 0; i < 64; i++) {
            n[i] = _node(ExprLib.Kind.CONST, 1, 0);
        }
        n[64] = _node(ExprLib.Kind.GT, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "nodes"));
        ev.validate(_enc(r, n), IEvaluatorV1.Phase.Trigger, principal, true);
    }

    function test_delistedOrRevokedDescriptorIsRefused() public {
        bytes memory t = _balanceAbove(1, principal, ExprLib.Subject.Principal);
        catalog.setRevoked(dBalance, true);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked"));
        ev.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
    }
}

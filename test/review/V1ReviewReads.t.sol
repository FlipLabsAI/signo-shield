// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./V1ReviewBase.sol";

contract ReviewWideReturn {
    function value() external pure returns (uint256) {
        assembly {
            mstore(0, 7)
            return(0, 65536)
        }
    }
}

contract ReviewReadHarness {
    function read(ExprLib.Read memory r, IDescriptors catalog) external view returns (int256) {
        return ExprLib.readValue(r, 0, catalog);
    }
}

contract V1ReviewReadsTest is V1ReviewBase {
    /// F13 (open, deferred): two descriptor words on one target still make two calls.
    function test_knownGapDifferentDescriptorWordsRepeatTheSameExternalRead() public {
        ReviewWideReturn wide = new ReviewWideReturn();
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(wide);
        d.selector = ReviewWideReturn.value.selector;
        d.subjectArg = -1;
        d.gasStipend = 100_000;
        d.copyBytes = 64;
        bytes32 first = core.listDescriptor(d);
        d.word = 1;
        bytes32 second = core.listDescriptor(d);
        ExprLib.Read[] memory reads = new ExprLib.Read[](2);
        reads[0] = ExprLib.Read(first, address(wide), "", ExprLib.Subject.None, 0);
        reads[1] = ExprLib.Read(second, address(wide), "", ExprLib.Subject.None, 0);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](3);
        nodes[0] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.READ), 1, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.GE), 0, 1);
        bytes memory t = abi.encode(reads, nodes);
        vm.expectCall(address(wide), abi.encodeCall(ReviewWideReturn.value, ()), uint64(2));
        assertTrue(evaluator.judgeTrigger(t, principal, new int256[](2), 0));
    }

    function test_fixListedWord255FailsClosed() public {
        ReviewWideReturn wide = new ReviewWideReturn();
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(wide);
        d.selector = ReviewWideReturn.value.selector;
        d.subjectArg = -1;
        d.gasStipend = 100_000;
        d.copyBytes = 8192;
        d.word = 255;
        bytes32 id = core.listDescriptor(d);
        ReviewReadHarness h = new ReviewReadHarness();
        ExprLib.Read memory r = ExprLib.Read(id, address(wide), "", ExprLib.Subject.None, 0);
        // F10 (fixed): no arithmetic panic; word 255 is read like any other.
        assertEq(h.read(r, core), 0);
    }

    /// F7 (fixed): the pinned decimals must be the instance's own.
    function test_fixShapeDecimalsArePinnedAtRegistration() public {
        assertEq(asset.decimals(), 18);
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.READ, 6);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "decimals"));
        core.registerMandate(p);
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        _register(p);
    }

    /// F5 (fixed): a suspended or revoked read target stops every firing that reads through it.
    function test_fixSuspendedAndRevokedReadTargetsStopFirings() public {
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        bytes32 id = _register(p);
        vm.prank(enforcer);
        core.suspend(address(asset));
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        _fire(id, 1e18, "");
        vm.prank(enforcer);
        core.revoke(address(asset));
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        _fire(id, 1e18, "");
        assertEq(core.getMandate(id).firings, 0);
    }

    /// F5 (fixed): a descriptor a SIGNED node names is checked at every judgement.
    function test_fixSignedOnlyRevokedDescriptorStopsFiring() public {
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.SIGNED, 18);
        bytes32 id = _register(p);
        vm.prank(enforcer);
        core.revokeDescriptor(balanceId);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked"));
        _fire(id, 1e18, "");
        assertEq(core.getMandate(id).firings, 0);
    }

    function test_controlLiveRevokedDescriptorStopsBeforeFundsMove() public {
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        bytes32 id = _register(p);
        uint256 before = asset.balanceOf(principal);
        vm.prank(enforcer);
        core.revokeDescriptor(balanceId);
        vm.expectRevert();
        _fire(id, 1e18, "");
        assertEq(asset.balanceOf(principal), before);
        assertEq(core.getMandate(id).firings, 0);
    }

    function test_controlDescriptorContentsAreWriteOnceAndDelistingDoesNotStopLiveRead() public {
        IDescriptors.Descriptor memory d = _descriptor(IERC20.balanceOf.selector);
        assertEq(core.listDescriptor(d), balanceId);
        d.gasStipend = 99_999;
        bytes32 other = core.listDescriptor(d);
        assertTrue(other != balanceId);
        (IDescriptors.Descriptor memory original,,) = core.descriptorOf(balanceId);
        assertEq(original.gasStipend, 100_000);
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        bytes32 id = _register(p);
        core.delistDescriptor(balanceId);
        _fire(id, 1e18, "");
        vm.expectRevert();
        _register(p);
    }

    /// F9 (fixed): delisting gates new trees only; an unchanged tree amends freely.
    function test_fixDelistingDoesNotBlockUnchangedTreeAmendment() public {
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        bytes32 id = _register(p);
        core.delistDescriptor(balanceId);
        p.maxTransactionValue = 500e18;
        vm.prank(principal);
        core.amendMandate(id, p);
        assertEq(core.getMandate(id).maxTransactionValue, 500e18);
        // A changed tree is a new tree and needs a listed descriptor.
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.SIGNED, 18);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptor"));
        core.amendMandate(id, p);
    }

    function test_controlRegistrationChecksFixedSubjectArgsTypesForwardReferencesAndRoot() public {
        bytes memory t = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        (ExprLib.Read[] memory reads, ExprLib.Node[] memory nodes) =
            abi.decode(t, (ExprLib.Read[], ExprLib.Node[]));
        reads[0].args = abi.encode(recipient);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        evaluator.validate(abi.encode(reads, nodes), IEvaluatorV1.Phase.Trigger, principal, true);
        reads[0].args = abi.encode(recipient, principal);
        vm.expectRevert();
        evaluator.validate(abi.encode(reads, nodes), IEvaluatorV1.Phase.Trigger, principal, true);
        reads[0].args = abi.encode(principal);
        nodes[2].kind = uint8(ExprLib.Kind.AND);
        vm.expectRevert();
        evaluator.validate(abi.encode(reads, nodes), IEvaluatorV1.Phase.Trigger, principal, true);
        nodes[2].kind = uint8(ExprLib.Kind.ADD);
        vm.expectRevert();
        evaluator.validate(abi.encode(reads, nodes), IEvaluatorV1.Phase.Trigger, principal, true);
        nodes[2].kind = uint8(ExprLib.Kind.GE);
        nodes[2].a = 2;
        vm.expectRevert();
        evaluator.validate(abi.encode(reads, nodes), IEvaluatorV1.Phase.Trigger, principal, true);
        nodes[2].a = 0;
        nodes[0].kind = uint8(ExprLib.Kind.BEFORE);
        vm.expectRevert();
        evaluator.validate(abi.encode(reads, nodes), IEvaluatorV1.Phase.Trigger, principal, true);
    }

    /// F11 (fixed): judgement rebinds the subject and enforces shape and limits.
    function test_fixJudgementRebindsSubjectAndChecksNodeCapAndRoot() public {
        bytes memory t = _tree(address(asset), balanceId, ExprLib.Kind.READ, 18);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        evaluator.judgeTrigger(t, recipient, new int256[](1), 0);
        ExprLib.Read[] memory reads = new ExprLib.Read[](0);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](65);
        for (uint256 i = 0; i < nodes.length; ++i) {
            nodes[i] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 1, 0);
        }
        bytes memory tooBig = abi.encode(reads, nodes);
        vm.expectRevert();
        evaluator.validate(tooBig, IEvaluatorV1.Phase.Trigger, principal, true);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "nodes"));
        evaluator.judgeTrigger(tooBig, principal, new int256[](0), 0);
    }

    function test_controlSharedReadRunsOnceAndSharedNodesStayLinear() public {
        ExprLib.Read[] memory reads = new ExprLib.Read[](1);
        reads[0] =
            ExprLib.Read(balanceId, address(asset), abi.encode(principal), ExprLib.Subject.Principal, 18);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](64);
        nodes[0] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.EQ), 0, 1);
        for (uint256 i = 3; i < nodes.length; ++i) {
            nodes[i] = ExprLib.Node(uint8(ExprLib.Kind.AND), i - 1, i - 1);
        }
        bytes memory t = abi.encode(reads, nodes);
        evaluator.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
        vm.expectCall(address(asset), abi.encodeCall(IERC20.balanceOf, (principal)), uint64(1));
        assertTrue(evaluator.judgeTrigger(t, principal, new int256[](1), 0));
    }

    function _feedDescriptor(MockFeed feed) internal pure returns (IDescriptors.Descriptor memory d) {
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(feed);
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.word = 1;
        d.isSigned = true;
        d.mustBePositive = true;
        d.decimals = 8;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = 3600;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
    }

    function test_controlRoundAgeFutureIncompleteAndPositiveRules() public {
        MockFeed feed = new MockFeed();
        bytes32 id = core.listDescriptor(_feedDescriptor(feed));
        ExprLib.Read memory r = ExprLib.Read(id, address(feed), "", ExprLib.Subject.None, 8);
        ReviewReadHarness h = new ReviewReadHarness();
        feed.set(10, 100, vm.getBlockTimestamp(), 10);
        assertEq(h.read(r, core), 100);
        feed.set(10, 100, vm.getBlockTimestamp(), 9);
        vm.expectRevert();
        h.read(r, core);
        feed.set(10, 100, vm.getBlockTimestamp() + 1, 10);
        vm.expectRevert();
        h.read(r, core);
        feed.set(10, 100, vm.getBlockTimestamp() - 3601, 10);
        vm.expectRevert();
        h.read(r, core);
        feed.set(10, 0, vm.getBlockTimestamp(), 10);
        vm.expectRevert();
        h.read(r, core);
        feed.set(10, -1, vm.getBlockTimestamp(), 10);
        vm.expectRevert();
        h.read(r, core);
    }

    /// F10 (fixed): a round descriptor cannot be listed without the positive-answer rule.
    function test_fixRoundDescriptorRequiresAnswerPositivity() public {
        MockFeed feed = new MockFeed();
        IDescriptors.Descriptor memory d = _feedDescriptor(feed);
        d.mustBePositive = false;
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.InvalidParams.selector, bytes32("freshness")));
        core.listDescriptor(d);
    }

    function test_controlBoundedCopyShortReturnStipendAndUnsignedRange() public {
        ReviewReadHarness h = new ReviewReadHarness();
        ReviewWideReturn wide = new ReviewWideReturn();
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(wide);
        d.selector = ReviewWideReturn.value.selector;
        d.subjectArg = -1;
        d.gasStipend = 100_000;
        d.copyBytes = 32;
        bytes32 id = core.listDescriptor(d);
        assertEq(h.read(ExprLib.Read(id, address(wide), "", ExprLib.Subject.None, 0), core), 7);
        MockNasty nasty = new MockNasty();
        d.target = address(nasty);
        d.selector = MockNasty.value.selector;
        id = core.listDescriptor(d);
        ExprLib.Read memory r = ExprLib.Read(id, address(nasty), "", ExprLib.Subject.None, 0);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        h.read(r, core);
        nasty.setShort(true);
        vm.expectRevert();
        h.read(r, core);
        nasty.setShort(false);
        nasty.setBurn(true);
        vm.expectRevert();
        h.read(r, core);
    }

    function test_controlArithmeticFailureCannotHideBehindTrueSibling() public {
        ExprLib.Read[] memory reads = new ExprLib.Read[](0);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](6);
        nodes[0] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 1, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 0, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.DIV), 0, 1);
        nodes[3] = ExprLib.Node(uint8(ExprLib.Kind.GE), 2, 1);
        nodes[4] = ExprLib.Node(uint8(ExprLib.Kind.EQ), 0, 0);
        nodes[5] = ExprLib.Node(uint8(ExprLib.Kind.OR), 4, 3);
        bytes memory t = abi.encode(reads, nodes);
        evaluator.validate(t, IEvaluatorV1.Phase.Trigger, principal, true);
        vm.expectRevert();
        evaluator.judgeTrigger(t, principal, new int256[](0), 0);
    }
}

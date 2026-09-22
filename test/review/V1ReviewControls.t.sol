// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "./V1ReviewBase.sol";
import {AaveV3AdapterV1} from "contracts/v1/AaveV3AdapterV1.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {MockDataProvider, MockAddressesProvider} from "test/mocks/MockAave.sol";

contract ReviewUnknownSemantics is IExecutorV1 {
    function semanticsOf(bytes32) external pure returns (uint8) {
        return 255;
    }
    function validateConfig(bytes32, address, bytes calldata) external pure {}

    function snapshot(Context calldata, uint256) external pure returns (bytes memory) {
        return "";
    }

    function execute(Context calldata, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

contract ReviewAccountingLens {
    ShieldV1 internal core;
    bytes32 public id;
    uint256 internal expected;

    constructor(ShieldV1 c, bytes32 i, uint256 want) {
        core = c;
        id = i;
        expected = want;
    }

    function value() external view returns (uint256) {
        IShieldV1.Mandate memory m = core.getMandate(id);
        return m.cumulativeUsed == expected && m.firings == 1 && m.lastFiredAt == block.timestamp ? 1 : 0;
    }
}

contract ReviewSupplyPool {
    address public immutable provider;
    MockToken internal receipt;

    constructor(address p, MockToken t) {
        provider = p;
        receipt = t;
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return provider;
    }

    function supply(address token, uint256 amount, address owner, uint16) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        receipt.mint(owner, amount);
    }
}

contract V1ReviewControlsTest is V1ReviewBase {
    function test_controlValidityCapsFrozenAgentAndOnlyAgent() public {
        IShieldV1.MandateParams memory p = _mockParams();
        p.validFrom = uint48(vm.getBlockTimestamp() + 1 hours);
        bytes32 id = _register(p);
        vm.expectRevert();
        _fire(id, 1e18, "");
        vm.warp(p.validFrom);
        vm.expectRevert();
        core.fire(id, 1e18, "");
        vm.expectRevert();
        _fire(id, 1_001e18, "");
        vm.prank(enforcer);
        registry.freezeAgent(agent);
        vm.expectRevert();
        _fire(id, 1e18, "");
        vm.prank(enforcer);
        registry.unfreezeAgent(agent);
        _fire(id, 1e18, "");
        vm.warp(uint256(p.validUntil) + 1);
        vm.expectRevert();
        _fire(id, 1e18, "");
    }

    function test_controlExpiredSignatureDoesNotConsumeNonce() public {
        bytes32 id = _register(_mockParams());
        uint256 deadline = vm.getBlockTimestamp();
        bytes memory sig = _signature(_digest(id, principal, 0, deadline, block.chainid, address(core)));
        vm.warp(deadline + 1);
        vm.expectRevert(IShieldV1.SignatureExpired.selector);
        core.revokeWithSig(id, deadline, sig);
        assertEq(core.sigNonces(principal), 0);
    }

    function test_controlOnlyPrincipalCanAmendRevokeAndRegistrationBindsCaller() public {
        IShieldV1.MandateParams memory p = _mockParams();
        bytes32 expected = keccak256(abi.encode(block.chainid, address(core), principal, uint256(0)));
        bytes32 id = _register(p);
        assertEq(id, expected);
        vm.prank(agent);
        vm.expectRevert(IShieldV1.NotPrincipal.selector);
        core.amendMandate(id, p);
        vm.expectRevert(IShieldV1.NotPrincipal.selector);
        core.revokeMandate(id);
        vm.prank(recipient);
        bytes32 ownId = core.registerMandate(p);
        assertEq(core.getMandate(ownId).principal, recipient);
        vm.prank(principal);
        core.revokeMandate(id);
        assertTrue(core.getMandate(id).revoked);
    }

    function test_controlPinnedExecutorEvaluatorAssetFundingAndAction() public {
        IShieldV1.MandateParams memory p = _mockParams();
        bytes32 id = _register(p);
        p.executor = address(generic);
        vm.prank(principal);
        vm.expectRevert();
        core.amendMandate(id, p);
        p = _mockParams();
        p.evaluator = address(0x123);
        vm.prank(principal);
        vm.expectRevert();
        core.amendMandate(id, p);
        p = _mockParams();
        p.asset = address(reward);
        vm.prank(principal);
        vm.expectRevert();
        core.amendMandate(id, p);
        p = _mockParams();
        p.funding = 1;
        vm.prank(principal);
        vm.expectRevert();
        core.amendMandate(id, p);
        p = _mockParams();
        p.action = keccak256("mock.claim");
        vm.prank(principal);
        vm.expectRevert();
        core.amendMandate(id, p);
    }

    function test_controlFeeCeilingsAndUnchangedRevisionBaselines() public {
        core.setFeeBps(10);
        core.setFeeRecipient(recipient);
        IShieldV1.MandateParams memory p = _mockParams();
        p.maxFeeBps = 9;
        vm.expectRevert();
        _register(p);
        p.maxFeeBps = 10;
        p.trigger = _tree(address(asset), balanceId, ExprLib.Kind.SIGNED, 18);
        p.outcome = p.trigger;
        bytes32 id = _register(p);
        IShieldV1.Mandate memory before = core.getMandate(id);
        _fire(id, 100e18, "");
        core.setFeeBps(1_000);
        p.maxTransactionValue = 500e18;
        vm.prank(principal);
        core.amendMandate(id, p);
        IShieldV1.Mandate memory after_ = core.getMandate(id);
        assertEq(after_.feeBps, 10);
        assertEq(after_.cumulativeUsed, 100.1e18);
        assertEq(after_.lastFiredAt, vm.getBlockTimestamp());
        assertEq(after_.firings, 1);
        assertEq(after_.triggerSigned[0], before.triggerSigned[0]);
        assertEq(after_.outcomeSigned[0], before.outcomeSigned[0]);
        p.maxFeeBps = 9;
        vm.prank(principal);
        vm.expectRevert();
        core.amendMandate(id, p);
        p.maxFeeBps = 10;
        (ExprLib.Read[] memory r, ExprLib.Node[] memory n) =
            abi.decode(p.trigger, (ExprLib.Read[], ExprLib.Node[]));
        n[1].a = 1;
        p.trigger = abi.encode(r, n);
        vm.prank(principal);
        core.amendMandate(id, p);
        assertEq(core.getMandate(id).triggerSigned[0], int256(asset.balanceOf(principal)));
        assertEq(core.getMandate(id).outcomeSigned[0], before.outcomeSigned[0]);
    }

    function testFuzz_controlChargesLargerOfMeasuredAndReported(
        uint96 rawAmount,
        uint16 spend,
        uint96 rawReport
    ) public {
        uint256 amount = bound(rawAmount, 1e6, 1_000e18);
        uint256 spendBps = bound(spend, 0, 10_000);
        uint256 report = bound(rawReport, 0, amount);
        core.setFeeBps(10);
        core.setFeeRecipient(recipient);
        bytes32 id = _register(_mockParams());
        mock.setSpendBps(spendBps);
        mock.setReport(true, report);
        uint256 measured = amount * spendBps / 10_000;
        uint256 charge = measured > report ? measured : report;
        uint256 expected = charge + charge * 10 / 10_000;
        assertEq(_fire(id, amount, ""), expected);
        assertEq(core.getMandate(id).cumulativeUsed, expected);
    }

    function test_controlExcessSpendAndNoneOutflowRevertNotClamp() public {
        bytes32 id = _register(_mockParams());
        mock.setReport(true, 101e18);
        vm.expectRevert();
        _fire(id, 100e18, "");
        mock.setReport(false, 0);
        mock.setExtraPull(1);
        vm.prank(principal);
        asset.approve(address(mock), 1e18);
        vm.expectRevert();
        _fire(id, 100e18, "");
        IShieldV1.MandateParams memory p = _mockParams();
        p.funding = 1;
        p.action = keccak256("mock.claim");
        p.maxTransactionValue = 0;
        p.maxCumulativeValue = 0;
        id = _register(p);
        vm.expectRevert();
        _fire(id, 0, "");
        mock.setExtraPull(0);
        mock.setReport(true, 1);
        vm.expectRevert();
        _fire(id, 0, "");
        assertEq(core.getMandate(id).firings, 0);
    }

    /// F10 (fixed): an unknown funding mode and an unknown semantics value both fail closed.
    function test_fixUnknownSemanticsAndUnknownFundingRejected() public {
        IShieldV1.MandateParams memory p = _mockParams();
        p.funding = 2;
        vm.expectRevert();
        _register(p);
        ReviewUnknownSemantics odd = new ReviewUnknownSemantics();
        registry.setExecutor(address(odd), true);
        p = _params(address(odd), bytes32(uint256(99)));
        vm.expectRevert();
        _register(p);
    }

    function test_controlOutcomeSeesFinalBookkeepingAndRollbackUndoesEverything() public {
        bytes32 predicted = keccak256(abi.encode(block.chainid, address(core), principal, uint256(0)));
        ReviewAccountingLens lens = new ReviewAccountingLens(core, predicted, 100e18);
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(lens);
        d.selector = ReviewAccountingLens.value.selector;
        d.subjectArg = -1;
        d.gasStipend = 300_000;
        d.copyBytes = 32;
        ExprLib.Read[] memory reads = new ExprLib.Read[](1);
        reads[0] = ExprLib.Read(registry.listDescriptor(d), address(lens), "", ExprLib.Subject.None, 0);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](3);
        nodes[0] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 1, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.EQ), 0, 1);
        IShieldV1.MandateParams memory p = _mockParams();
        p.outcome = abi.encode(reads, nodes);
        bytes32 id = _register(p);
        _fire(id, 100e18, "");
        uint256 before = asset.balanceOf(principal);
        vm.expectRevert(); // lens only accepts one firing and 100 total
        _fire(id, 100e18, "");
        assertEq(asset.balanceOf(principal), before);
        assertEq(core.getMandate(id).cumulativeUsed, 100e18);
        assertEq(core.getMandate(id).firings, 1);
    }

    /// F5 (fixed): a suspended or revoked executor or evaluator stops every firing.
    function test_fixSuspendedOrRevokedExecutorAndEvaluatorStopFirings() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        bytes memory route = _route(_swap(address(asset), 100e18, generic.nextClone(id)));
        vm.prank(enforcer);
        registry.suspend(address(generic));
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.EXECUTOR_HALTED
            )
        );
        _fire(id, 100e18, route);
        vm.prank(enforcer);
        registry.suspend(address(evaluator));
        vm.prank(enforcer);
        registry.revoke(address(generic));
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.EXECUTOR_HALTED
            )
        );
        _fire(id, 100e18, route);
        assertEq(core.getMandate(id).firings, 0);
    }

    /// F5 (fixed): the Aave adapter refuses to act on a suspended or revoked pool.
    function test_fixRevokedAavePoolStopsSupply() public {
        MockToken receipt = new MockToken();
        MockDataProvider dp = new MockDataProvider();
        dp.set(address(asset), address(receipt), address(output));
        MockAddressesProvider provider = new MockAddressesProvider(address(oracle), address(dp));
        ReviewSupplyPool pool = new ReviewSupplyPool(address(provider), receipt);
        AaveV3AdapterV1 adapter = new AaveV3AdapterV1(address(core), IPool(address(pool)));
        registry.setExecutor(address(adapter), true);
        bytes32 id = _register(_params(address(adapter), adapter.ACTION_SUPPLY()));
        vm.prank(enforcer);
        registry.revoke(address(pool));
        vm.expectRevert();
        _fire(id, 100e18, "");
        assertEq(receipt.balanceOf(principal), 0);
        assertEq(asset.balanceOf(address(pool)), 0);
    }

    function test_controlHaltAndLiftEpochsDelayRolesAndPermanentRevocation() public {
        vm.expectRevert();
        registry.halt(address(generic));
        vm.prank(enforcer);
        registry.halt(address(generic));
        vm.prank(enforcer);
        registry.queueUnhalt(address(generic), 1);
        vm.expectRevert();
        registry.executeUnhalt(address(generic), 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(enforcer);
        vm.expectRevert();
        registry.executeUnhalt(address(generic), 1);
        registry.executeUnhalt(address(generic), 1);
        assertFalse(registry.isHalted(address(generic)));
        vm.startPrank(enforcer);
        registry.halt(address(generic));
        registry.queueUnhalt(address(generic), 2);
        registry.halt(address(generic));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        registry.executeUnhalt(address(generic), 2);
        vm.startPrank(enforcer);
        registry.suspend(address(dex));
        registry.queueLift(address(dex), 1);
        registry.suspend(address(dex));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        registry.executeLift(address(dex), 1);
        vm.prank(enforcer);
        registry.queueLift(address(dex), 2);
        vm.prank(enforcer);
        registry.revoke(address(dex));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        registry.executeLift(address(dex), 2);
        assertTrue(registry.isVenueBlocked(address(dex)));
        vm.expectRevert();
        registry.setEnforcer(address(this), true);
        vm.expectRevert();
        core.transferOwnership(enforcer);
    }

    function _digest(
        bytes32 id,
        address owner,
        uint256 nonce,
        uint256 deadline,
        uint256 chain,
        address verifying
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SignoShield"),
                keccak256("1"),
                chain,
                verifying
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Revoke(bytes32 mandateId,address principal,uint256 nonce,uint256 deadline)"),
                id,
                owner,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _signature(bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_controlSignedRevocationBindsEveryFieldAndSupports1271() public {
        bytes32 id = _register(_mockParams());
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32[6] memory bad;
        bad[0] = _digest(id, principal, 0, deadline, block.chainid + 1, address(core));
        bad[1] = _digest(id, principal, 0, deadline, block.chainid, address(generic));
        bad[2] = _digest(bytes32(uint256(1)), principal, 0, deadline, block.chainid, address(core));
        bad[3] = _digest(id, recipient, 0, deadline, block.chainid, address(core));
        bad[4] = _digest(id, principal, 1, deadline, block.chainid, address(core));
        bad[5] = _digest(id, principal, 0, deadline + 1, block.chainid, address(core));
        for (uint256 i = 0; i < bad.length; ++i) {
            bytes memory sig = _signature(bad[i]);
            vm.expectRevert(IShieldV1.BadSignature.selector);
            core.revokeWithSig(id, deadline, sig);
        }
        assertEq(core.sigNonces(principal), 0);
        bytes memory good = _signature(_digest(id, principal, 0, deadline, block.chainid, address(core)));
        core.revokeWithSig(id, deadline, good);
        assertTrue(core.getMandate(id).revoked);
        vm.expectRevert();
        core.revokeWithSig(id, deadline, good);
        MockWallet1271 wallet = new MockWallet1271(principal);
        IShieldV1.MandateParams memory p = _mockParams();
        vm.prank(address(wallet));
        id = core.registerMandate(p);
        bytes32 digest = _digest(id, address(wallet), 0, deadline, block.chainid, address(core));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        core.revokeWithSig(id, deadline, abi.encode(v, r, s));
        assertTrue(core.getMandate(id).revoked);
    }
}

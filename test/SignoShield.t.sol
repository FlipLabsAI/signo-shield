// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShieldAdapter} from "../contracts/core/interfaces/IShieldAdapter.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

/// Core enforcement (FLIP-191). Every reason code, every rejection path, the
/// budget arithmetic, the amendment rules and the role split, driven through
/// the real contract with a configurable adapter.
contract SignoShieldTest is Test {
    SignoShield internal shield;
    ConditionModule internal conditions;
    MockAdapter internal adapter;
    MockERC20 internal token;
    MockTarget internal target;

    address internal admin = makeAddr("admin");
    address internal enforcer = makeAddr("enforcer");
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");
    address internal feeSink = makeAddr("feeSink");

    bytes32 internal constant ACTION = keccak256("mock.spend");
    bytes32 internal constant ACTION_OTHER = keccak256("mock.other");
    address internal constant SINK = address(0xdead);
    uint16 internal constant FEE_BPS = 10;
    uint256 internal constant TX_CAP = 100e6;
    uint256 internal constant LIFETIME = 250e6;
    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    function setUp() public {
        vm.warp(1_800_000_000);
        conditions = new ConditionModule();
        shield = new SignoShield(admin, conditions, FEE_BPS);
        adapter = new MockAdapter(address(shield));
        token = new MockERC20("Mock USD", "mUSD", 6);
        target = new MockTarget();

        vm.startPrank(admin);
        shield.setAdapter(address(adapter), true);
        shield.setEnforcer(enforcer, true);
        vm.stopPrank();

        token.mint(principal, 1_000e6);
        vm.prank(principal);
        token.approve(address(shield), type(uint256).max);
    }

    // ------------------------------------------------------------- helpers

    function _noCondition() internal pure returns (ICondition.Condition memory) {
        return ICondition.Condition({
            target: address(0),
            callData: "",
            wordOffset: 0,
            comparator: ICondition.Comparator.LessThan,
            threshold: 0,
            evaluator: address(0)
        });
    }

    /// "word 2 of target.read() < threshold": a health-factor-shaped trigger.
    function _hfBelow(uint256 threshold) internal view returns (ICondition.Condition memory) {
        return ICondition.Condition({
            target: address(target),
            callData: abi.encodeCall(MockTarget.read, ()),
            wordOffset: 2,
            comparator: ICondition.Comparator.LessThan,
            threshold: threshold,
            evaluator: address(0)
        });
    }

    function _params() internal pure returns (ISignoShield.MandateParams memory p) {
        p.agent = address(0);
        p.action = ACTION;
        p.maxTransactionValue = TX_CAP;
        p.maxCumulativeValue = LIFETIME;
        p.validFrom = 0;
        p.validUntil = VALID_UNTIL;
        p.condition = _noCondition();
        p.actionConfig = "";
    }

    function _defaultParams() internal view returns (ISignoShield.MandateParams memory p) {
        p = _params();
        p.agent = agent;
        p.adapter = address(adapter);
        p.asset = address(token);
    }

    function _register() internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(_defaultParams());
    }

    function _register(ISignoShield.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _blocked(bytes32 id, ISignoShield.MandateReason r) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISignoShield.MandateBlocked.selector, id, r);
    }

    /// What `fire` reverts with when the adapter reverts with `inner`.
    function _rejected(bytes32 id, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ISignoShield.OutcomeRejected.selector, id, ISignoShield.MandateReason.POSTCONDITION_FAILED, inner
        );
    }

    function _fire(bytes32 id, uint256 amount) internal returns (uint256) {
        vm.prank(agent);
        return shield.fire(id, amount, "");
    }

    function _assertReason(bytes32 id, uint256 amount, ISignoShield.MandateReason expected) internal view {
        (bool ok, ISignoShield.MandateReason r) = shield.canFire(id, amount);
        assertEq(uint8(r), uint8(expected), "reason");
        assertEq(ok, expected == ISignoShield.MandateReason.OK, "ok");
    }

    // ---------------------------------------------------------- registration

    function test_register_storesTheRecordAndEmitsTheWholeThing() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.condition = _hfBelow(1.5e18);
        p.actionConfig = hex"c0ffee";
        p.validFrom = uint48(block.timestamp);

        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(shield), principal, uint256(0)));
        ISignoShield.Mandate memory expected = ISignoShield.Mandate({
            principal: principal,
            agent: agent,
            asset: address(token),
            validFrom: p.validFrom,
            validUntil: p.validUntil,
            revoked: false,
            maxTransactionValue: TX_CAP,
            maxCumulativeValue: LIFETIME,
            cumulativeUsed: 0,
            adapter: address(adapter),
            action: ACTION,
            feeBps: FEE_BPS,
            condition: p.condition,
            actionConfig: p.actionConfig
        });
        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.MandateRendered(principal, agent, expectedId, expected);

        bytes32 id = _register(p);
        assertEq(id, expectedId);
        assertEq(shield.nonces(principal), 1);

        ISignoShield.Mandate memory m = shield.getMandate(id);
        assertEq(m.principal, principal);
        assertEq(m.agent, agent);
        assertEq(m.adapter, address(adapter));
        assertEq(m.action, ACTION);
        assertEq(m.asset, address(token));
        assertEq(m.maxTransactionValue, TX_CAP);
        assertEq(m.maxCumulativeValue, LIFETIME);
        assertEq(m.cumulativeUsed, 0);
        assertEq(m.feeBps, FEE_BPS, "stamped from the Shield, not chosen");
        assertEq(m.condition.target, address(target));
        assertEq(m.condition.wordOffset, 2);
        assertEq(m.condition.threshold, 1.5e18);
        assertEq(m.actionConfig, hex"c0ffee");
        assertFalse(m.revoked);
    }

    function test_register_idsAreUniquePerPrincipalAndChain() public {
        bytes32 a = _register();
        bytes32 b = _register();
        assertTrue(a != b);
        vm.prank(stranger);
        vm.expectRevert(); // stranger has no allowance, but registration does not need one; it is the adapter
        // that will reject nothing here, so this only proves ids differ per principal below.
        shield.revokeMandate(a);
        ISignoShield.MandateParams memory p = _defaultParams();
        p.agent = agent;
        vm.prank(stranger);
        bytes32 c = shield.registerMandate(p);
        assertTrue(c != a && c != b);
    }

    function test_register_principalIsNeverAParameter() public {
        bytes32 id = _register();
        assertEq(shield.getMandate(id).principal, principal);
        // Nothing in MandateParams can name another principal; the struct has no such field.
    }

    function test_register_rejectsUnlistedAdapter() public {
        MockAdapter other = new MockAdapter(address(shield));
        ISignoShield.MandateParams memory p = _defaultParams();
        p.adapter = address(other);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdapterNotListed.selector, address(other)));
        _register(p);
    }

    function test_register_rejectsUnsupportedAction() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.action = keccak256("nope");
        vm.expectRevert(
            abi.encodeWithSelector(
                ISignoShield.ActionNotSupported.selector, address(adapter), keccak256("nope")
            )
        );
        _register(p);
    }

    function test_register_adapterGetsTheLastWordOnConfig() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.actionConfig = "bad";
        vm.expectRevert("mock: bad config");
        _register(p);
    }

    function test_register_rejectsBadAgent() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.agent = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "agent"));
        _register(p);
        p.agent = principal;
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "agent"));
        _register(p);
        p.agent = address(shield);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "agent"));
        _register(p);
    }

    function test_register_rejectsBadNumbers() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.asset = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "asset"));
        _register(p);

        p = _defaultParams();
        p.maxTransactionValue = 0;
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "maxTransactionValue"));
        _register(p);

        p = _defaultParams();
        p.maxCumulativeValue = TX_CAP - 1;
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "maxCumulativeValue"));
        _register(p);

        p = _defaultParams();
        p.validUntil = uint48(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "validUntil"));
        _register(p);

        p = _defaultParams();
        p.validFrom = VALID_UNTIL;
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "validUntil"));
        _register(p);
    }

    function test_fee_capIsEnforcedOnTheShieldFee() public {
        uint16 cap = shield.MAX_FEE_BPS();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "feeBps"));
        shield.setFeeBps(cap + 1);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "feeBps"));
        new SignoShield(admin, conditions, cap + 1);
        vm.prank(admin);
        shield.setFeeBps(cap);
        assertEq(shield.feeBps(), cap);
    }

    function test_register_rejectsHalfSpecifiedCondition() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.condition.callData = hex"01";
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "condition"));
        _register(p);

        p = _defaultParams();
        p.condition.target = address(target);
        p.condition.callData = hex"0102";
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "condition"));
        _register(p);
    }

    // ------------------------------------------------------- reason codes

    function test_reason_nonexistent() public {
        bytes32 id = keccak256("nothing");
        _assertReason(id, 1, ISignoShield.MandateReason.NONEXISTENT);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.NONEXISTENT));
        shield.fire(id, 1, "");
    }

    function test_reason_agentFrozen_andUnfreezeRestores() public {
        bytes32 id = _register();
        vm.prank(enforcer);
        shield.freezeAgent(agent);
        assertTrue(shield.isAgentFrozen(agent));
        _assertReason(id, 1, ISignoShield.MandateReason.AGENT_FROZEN);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.AGENT_FROZEN));
        shield.fire(id, 1, "");

        vm.prank(enforcer);
        shield.unfreezeAgent(agent);
        _assertReason(id, 1, ISignoShield.MandateReason.OK);
        assertEq(_fire(id, 1), 1);
    }

    function test_reason_notAgent() public {
        bytes32 id = _register();
        // canFire assumes the mandate's agent; fire checks the real caller.
        _assertReason(id, 1, ISignoShield.MandateReason.OK);
        vm.prank(stranger);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.NOT_AGENT));
        shield.fire(id, 1, "");
        vm.prank(principal);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.NOT_AGENT));
        shield.fire(id, 1, "");
    }

    function test_reason_notYetValid() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.validFrom = uint48(block.timestamp + 1 days);
        bytes32 id = _register(p);
        _assertReason(id, 1, ISignoShield.MandateReason.NOT_YET_VALID);
        vm.warp(block.timestamp + 1 days);
        _assertReason(id, 1, ISignoShield.MandateReason.OK);
    }

    function test_reason_expired() public {
        bytes32 id = _register();
        vm.warp(VALID_UNTIL);
        _assertReason(id, 1, ISignoShield.MandateReason.OK);
        vm.warp(uint256(VALID_UNTIL) + 1);
        _assertReason(id, 1, ISignoShield.MandateReason.EXPIRED);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.EXPIRED));
        shield.fire(id, 1, "");
    }

    function test_reason_revoked() public {
        bytes32 id = _register();
        vm.prank(principal);
        shield.revokeMandate(id);
        _assertReason(id, 1, ISignoShield.MandateReason.REVOKED);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.REVOKED));
        shield.fire(id, 1, "");
    }

    function test_reason_zeroAmount() public {
        bytes32 id = _register();
        _assertReason(id, 0, ISignoShield.MandateReason.ZERO_AMOUNT);
    }

    function test_reason_overTxCap() public {
        bytes32 id = _register();
        _assertReason(id, TX_CAP, ISignoShield.MandateReason.OK);
        _assertReason(id, TX_CAP + 1, ISignoShield.MandateReason.OVER_TX_CAP);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_TX_CAP));
        shield.fire(id, TX_CAP + 1, "");
    }

    /// Several firings each under the per-firing cap that together cross the lifetime cap.
    function test_reason_overCumulativeCap() public {
        bytes32 id = _register();
        _fire(id, TX_CAP);
        _fire(id, TX_CAP);
        assertEq(shield.getMandate(id).cumulativeUsed, 200e6);
        _assertReason(id, 50e6, ISignoShield.MandateReason.OK);
        _assertReason(id, 50e6 + 1, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP));
        shield.fire(id, 50e6 + 1, "");
        _fire(id, 50e6);
        _assertReason(id, 1, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP);
    }

    function test_reason_triggerNotMet_andMet() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.condition = _hfBelow(1.5e18);
        bytes32 id = _register(p);

        target.set(0, 0, 1.6e18);
        _assertReason(id, 1, ISignoShield.MandateReason.TRIGGER_NOT_MET);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.TRIGGER_NOT_MET));
        shield.fire(id, 1, "");

        target.set(0, 0, 1.49e18);
        _assertReason(id, 1, ISignoShield.MandateReason.OK);
        assertEq(_fire(id, 1), 1);
    }

    /// A trigger that cannot be read reverts. It is never reported as "not met".
    function test_trigger_unreadableRevertsInsteadOfDenying() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.condition = _hfBelow(1.5e18);
        bytes32 id = _register(p);
        target.setFail(true);
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ConditionCallFailed.selector, address(target)));
        shield.canFire(id, 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ConditionCallFailed.selector, address(target)));
        shield.fire(id, 1, "");
    }

    /// The order is fixed: the first failing check is the answer.
    function test_reason_orderIsFixed() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.condition = _hfBelow(1.5e18);
        target.set(0, 0, 2e18); // trigger false
        bytes32 id = _register(p);

        // Over both caps and trigger false: tx cap is reported first.
        _assertReason(id, LIFETIME + 1, ISignoShield.MandateReason.OVER_TX_CAP);
        // Zero amount before the caps.
        _assertReason(id, 0, ISignoShield.MandateReason.ZERO_AMOUNT);
        // Revoked before the caps.
        vm.prank(principal);
        shield.revokeMandate(id);
        _assertReason(id, LIFETIME + 1, ISignoShield.MandateReason.REVOKED);
        // Expired before revoked.
        vm.warp(uint256(VALID_UNTIL) + 1);
        _assertReason(id, 1, ISignoShield.MandateReason.EXPIRED);
        // Frozen before everything but nonexistent.
        vm.prank(enforcer);
        shield.freezeAgent(agent);
        _assertReason(id, 1, ISignoShield.MandateReason.AGENT_FROZEN);
        _assertReason(keccak256("nothing"), 1, ISignoShield.MandateReason.NONEXISTENT);
    }

    // -------------------------------------------------------------- firing

    function test_fire_movesFundsPrincipalToAdapterAndAccounts() public {
        bytes32 id = _register();
        uint256 before = token.balanceOf(principal);

        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.MandateFired(id, agent, address(adapter), ACTION, 40e6, 40e6, 0);
        uint256 spent = _fire(id, 40e6);

        assertEq(spent, 40e6);
        assertEq(token.balanceOf(principal), before - 40e6);
        assertEq(token.balanceOf(address(shield)), 0, "the Shield holds nothing");
        assertEq(token.balanceOf(address(adapter)), 0, "the adapter holds nothing after");
        assertEq(token.balanceOf(SINK), 40e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 40e6);
        assertEq(adapter.lastMandateId(), id);
        assertEq(adapter.lastPrincipal(), principal);
        assertEq(adapter.lastAgent(), agent);
        assertEq(adapter.lastAsset(), address(token));
        assertEq(adapter.lastAmount(), 40e6);
    }

    function test_fire_passesDataAndConfigThrough() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.actionConfig = hex"c0ffee";
        bytes32 id = _register(p);
        vm.prank(agent);
        shield.fire(id, 1e6, hex"beef");
        assertEq(adapter.lastConfig(), hex"c0ffee");
        assertEq(adapter.lastData(), hex"beef");
    }

    /// Unspent amount comes back and the budget is reconciled to what was spent.
    function test_fire_reconcilesBudgetToActualSpend() public {
        bytes32 id = _register();
        adapter.setSpendBps(2_500);
        uint256 before = token.balanceOf(principal);
        uint256 spent = _fire(id, 40e6);
        assertEq(spent, 10e6);
        assertEq(token.balanceOf(principal), before - 10e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 10e6);
    }

    function test_fire_adapterCannotReportMoreThanItGot() public {
        bytes32 id = _register();
        adapter.setOverReport(true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.SpendExceedsAmount.selector, 40e6 + 1, 40e6));
        shield.fire(id, 40e6, "");
    }

    /// A failed outcome is a whole-transaction failure: no funds move, no budget is used.
    function test_fire_failedOutcomeRollsEverythingBack() public {
        bytes32 id = _register();
        _fire(id, 10e6);
        adapter.setShouldRevert(true);
        uint256 before = token.balanceOf(principal);
        vm.prank(agent);
        vm.expectRevert(_rejected(id, abi.encodeWithSignature("Error(string)", "mock: outcome failed")));
        shield.fire(id, 40e6, "");
        assertEq(token.balanceOf(principal), before);
        assertEq(shield.getMandate(id).cumulativeUsed, 10e6);
    }

    function test_fire_reentrantFiringIsRefused() public {
        bytes32 id = _register();
        adapter.setReenter(true);
        vm.prank(agent);
        // The guard runs before any check, so a nested fire is refused whoever
        // the adapter claims to be; the adapter's revert surfaces as a rejected
        // outcome and the whole outer firing reverts with it.
        bytes memory guard = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.expectRevert(_rejected(id, guard));
        shield.fire(id, 40e6, "");
        assertEq(shield.getMandate(id).cumulativeUsed, 0);

        // Adapter-as-agent: the reentrancy guard is what stops it.
        ISignoShield.MandateParams memory p = _defaultParams();
        p.agent = address(adapter);
        bytes32 id2 = _register(p);
        vm.prank(address(adapter));
        vm.expectRevert(_rejected(id2, guard));
        shield.fire(id2, 40e6, "");
    }

    /// Raising the token allowance later does not touch the Shield's counter.
    function test_fire_allowanceChangeDoesNotResetBudget() public {
        bytes32 id = _register();
        _fire(id, TX_CAP);
        _fire(id, TX_CAP);
        vm.prank(principal);
        token.approve(address(shield), type(uint256).max);
        assertEq(shield.getMandate(id).cumulativeUsed, 200e6);
        _assertReason(id, 50e6 + 1, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP);
    }

    /// Two mandates on one principal keep separate ledgers.
    function test_fire_mandatesAreIsolated() public {
        bytes32 a = _register();
        bytes32 b = _register();
        _fire(a, TX_CAP);
        _fire(a, TX_CAP);
        _fire(a, 50e6);
        _assertReason(a, 1, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP);
        _assertReason(b, TX_CAP, ISignoShield.MandateReason.OK);
        assertEq(shield.getMandate(b).cumulativeUsed, 0);
    }

    /// Whatever sequence of firings, the counter never exceeds the lifetime cap
    /// and always equals what actually left the principal.
    function testFuzz_fire_budgetNeverExceedsLifetime(
        uint256[8] memory amounts,
        uint16 spendBps,
        bool withFee
    ) public {
        spendBps = uint16(bound(spendBps, 0, 10_000));
        adapter.setSpendBps(spendBps);
        if (withFee) {
            vm.prank(admin);
            shield.setFeeRecipient(feeSink);
        }
        bytes32 id = _register();
        uint256 before = token.balanceOf(principal);
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 0, 2 * TX_CAP);
            (bool ok,) = shield.canFire(id, amount);
            vm.prank(agent);
            if (ok) {
                shield.fire(id, amount, "");
            } else {
                vm.expectRevert();
                shield.fire(id, amount, "");
            }
            uint256 used = shield.getMandate(id).cumulativeUsed;
            assertLe(used, LIFETIME);
            assertEq(before - token.balanceOf(principal), used);
        }
    }

    // ----------------------------------------------------------------- fees

    function test_fee_takenOnlyWhenRecipientSet() public {
        vm.prank(admin);
        shield.setFeeBps(100); // 1%, stamped into the next registration
        bytes32 id = _register();
        assertEq(shield.getMandate(id).feeBps, 100);

        // No recipient: no fee, whatever the mandate says.
        uint256 spent = _fire(id, 50e6);
        assertEq(spent, 50e6);
        assertEq(token.balanceOf(feeSink), 0);
        assertEq(adapter.lastAmount(), 50e6);

        vm.prank(admin);
        shield.setFeeRecipient(feeSink);
        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.MandateFired(id, agent, address(adapter), ACTION, 50e6, 50.5e6, 0.5e6);
        spent = _fire(id, 50e6);
        assertEq(spent, 50.5e6, "amount spent plus the fee on it");
        assertEq(token.balanceOf(feeSink), 0.5e6);
        assertEq(adapter.lastAmount(), 50e6, "the adapter gets the whole amount; the fee is on top");
        assertEq(shield.getMandate(id).cumulativeUsed, 100.5e6, "fee counts against the budget");
    }

    /// The fee is on what was spent, not on what was asked for.
    function test_fee_isOnWhatWasSpent() public {
        vm.prank(admin);
        shield.setFeeBps(100);
        bytes32 id = _register();
        vm.prank(admin);
        shield.setFeeRecipient(feeSink);
        adapter.setSpendBps(2_500);
        uint256 before = token.balanceOf(principal);
        uint256 spent = _fire(id, 50e6);
        assertEq(spent, 12.5e6 + 0.125e6);
        assertEq(token.balanceOf(feeSink), 0.125e6, "1% of the 12.5 spent, not of the 50 asked");
        assertEq(before - token.balanceOf(principal), 12.625e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 12.625e6);

        adapter.setSpendBps(0);
        spent = _fire(id, 50e6);
        assertEq(spent, 0, "nothing spent, no fee");
        assertEq(token.balanceOf(feeSink), 0.125e6);
    }

    /// The lifetime cap covers the fee: the worst case (all spent, fee on all)
    /// is what has to fit, and what is reserved before the adapter runs.
    function test_fee_worstCaseIsReservedAgainstTheLifetimeCap() public {
        vm.prank(admin);
        shield.setFeeRecipient(feeSink);
        bytes32 id = _register(); // 10 bps, lifetime 250e6
        _fire(id, TX_CAP);
        _fire(id, TX_CAP);
        assertEq(shield.getMandate(id).cumulativeUsed, 200.2e6);
        _assertReason(id, 49e6, ISignoShield.MandateReason.OK); // 49.049 fits in 49.8
        _assertReason(id, 49.8e6, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP); // 49.8498 does not
        _fire(id, 49e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 249.249e6);
        assertLe(shield.getMandate(id).cumulativeUsed, LIFETIME);
    }

    // ------------------------------------------------------------ amendment

    function test_amend_reRendersAndKeepsTheCounter() public {
        bytes32 id = _register();
        _fire(id, 30e6);

        ISignoShield.MandateParams memory p = _defaultParams();
        p.maxTransactionValue = 10e6;
        p.maxCumulativeValue = 60e6;
        p.validUntil = VALID_UNTIL + 1;
        p.condition = _hfBelow(1.2e18);
        p.actionConfig = hex"01";
        target.set(0, 0, 1e18);

        // The emitted record must be the POST-amend one (FLIP-201 I-8).
        ISignoShield.Mandate memory expected = shield.getMandate(id);
        expected.maxTransactionValue = 10e6;
        expected.maxCumulativeValue = 60e6;
        expected.validUntil = VALID_UNTIL + 1;
        expected.condition = p.condition;
        expected.actionConfig = hex"01";
        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.MandateRendered(principal, agent, id, expected);
        vm.prank(principal);
        shield.amendMandate(id, p);

        ISignoShield.Mandate memory m = shield.getMandate(id);
        assertEq(m.cumulativeUsed, 30e6, "counter survives amendment");
        assertEq(m.maxTransactionValue, 10e6);
        assertEq(m.maxCumulativeValue, 60e6);
        assertEq(m.validUntil, VALID_UNTIL + 1);
        assertEq(m.condition.threshold, 1.2e18);
        assertEq(m.actionConfig, hex"01");
        _assertReason(id, 10e6, ISignoShield.MandateReason.OK);
        _assertReason(id, 10e6 + 1, ISignoShield.MandateReason.OVER_TX_CAP);
        // 30e6 used of the new 60e6 lifetime: three more firings, then the cap.
        _fire(id, 10e6);
        _fire(id, 10e6);
        _fire(id, 10e6);
        _assertReason(id, 1, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP);
    }

    function test_amend_extendsAnExpiredMandateWithoutResettingUsage() public {
        bytes32 id = _register();
        _fire(id, 30e6);
        vm.warp(uint256(VALID_UNTIL) + 1);
        _assertReason(id, 1, ISignoShield.MandateReason.EXPIRED);
        ISignoShield.MandateParams memory p = _defaultParams();
        p.validUntil = uint48(block.timestamp + 1 days);
        vm.prank(principal);
        shield.amendMandate(id, p);
        _assertReason(id, 1, ISignoShield.MandateReason.OK);
        assertEq(shield.getMandate(id).cumulativeUsed, 30e6);
    }

    function test_amend_onlyPrincipal() public {
        bytes32 id = _register();
        ISignoShield.MandateParams memory p = _defaultParams();
        vm.prank(agent);
        vm.expectRevert(ISignoShield.NotPrincipal.selector);
        shield.amendMandate(id, p);
        vm.prank(admin);
        vm.expectRevert(ISignoShield.NotPrincipal.selector);
        shield.amendMandate(id, p);
        vm.prank(principal);
        vm.expectRevert(_blocked(keccak256("nothing"), ISignoShield.MandateReason.NONEXISTENT));
        shield.amendMandate(keccak256("nothing"), p);
    }

    function test_amend_cannotChangeWhoWhatOrWhich() public {
        bytes32 id = _register();
        ISignoShield.MandateParams memory p = _defaultParams();

        p.agent = stranger;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.FieldImmutable.selector, "agent"));
        shield.amendMandate(id, p);

        p = _defaultParams();
        p.adapter = address(new MockAdapter(address(shield)));
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.FieldImmutable.selector, "adapter"));
        shield.amendMandate(id, p);

        p = _defaultParams();
        p.action = ACTION_OTHER;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.FieldImmutable.selector, "action"));
        shield.amendMandate(id, p);

        p = _defaultParams();
        p.asset = address(new MockERC20("x", "x", 18));
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.FieldImmutable.selector, "asset"));
        shield.amendMandate(id, p);
    }

    /// The fee is part of what the principal signed: a Shield fee change
    /// reaches new registrations only, and amendment never touches it.
    function test_fee_changeReachesNewMandatesOnly() public {
        bytes32 earlier = _register();
        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.FeeBpsSet(50);
        vm.prank(admin);
        shield.setFeeBps(50);
        bytes32 later = _register();
        assertEq(shield.getMandate(earlier).feeBps, FEE_BPS);
        assertEq(shield.getMandate(later).feeBps, 50);

        vm.prank(principal);
        shield.amendMandate(earlier, _defaultParams());
        assertEq(shield.getMandate(earlier).feeBps, FEE_BPS, "amendment keeps the stamped fee");

        vm.prank(admin);
        shield.setFeeRecipient(feeSink);
        _fire(earlier, 100e6);
        _fire(later, 100e6);
        assertEq(token.balanceOf(feeSink), 0.1e6 + 0.5e6, "10 bps on the old mandate, 50 on the new");
    }

    function test_amend_cannotMoveTheCapUnderWhatIsUsed() public {
        bytes32 id = _register();
        _fire(id, TX_CAP);
        ISignoShield.MandateParams memory p = _defaultParams();
        p.maxCumulativeValue = TX_CAP - 1;
        p.maxTransactionValue = TX_CAP - 1;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "maxCumulativeValue"));
        shield.amendMandate(id, p);
    }

    function test_amend_revokedIsFinal() public {
        bytes32 id = _register();
        vm.prank(principal);
        shield.revokeMandate(id);
        vm.prank(principal);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.REVOKED));
        shield.amendMandate(id, _defaultParams());
    }

    /// The adapter is pinned: delisting it later changes nothing for a live mandate.
    function test_amend_andFire_survivesAdapterDelisting() public {
        bytes32 id = _register();
        vm.prank(admin);
        shield.setAdapter(address(adapter), false);
        assertFalse(shield.isAdapterListed(address(adapter)));

        assertEq(_fire(id, 10e6), 10e6);
        ISignoShield.MandateParams memory p = _defaultParams();
        p.maxTransactionValue = 5e6;
        vm.prank(principal);
        shield.amendMandate(id, p);
        assertEq(shield.getMandate(id).maxTransactionValue, 5e6);

        // ...but no NEW mandate can pin it.
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdapterNotListed.selector, address(adapter)));
        _register();
    }

    // ----------------------------------------------------------- revocation

    function test_revoke_onlyPrincipalAndOnlyOnce() public {
        bytes32 id = _register();
        vm.prank(agent);
        vm.expectRevert(ISignoShield.NotPrincipal.selector);
        shield.revokeMandate(id);
        vm.prank(enforcer);
        vm.expectRevert(ISignoShield.NotPrincipal.selector);
        shield.revokeMandate(id);

        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.MandateRevoked(id, principal);
        vm.prank(principal);
        shield.revokeMandate(id);
        assertTrue(shield.getMandate(id).revoked);

        vm.prank(principal);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.REVOKED));
        shield.revokeMandate(id);
    }

    // ---------------------------------------------------------------- roles

    function test_roles_adminCannotFreezeOrRevoke() public {
        bytes32 id = _register();
        vm.prank(admin);
        vm.expectRevert(ISignoShield.NotEnforcer.selector);
        shield.freezeAgent(agent);
        vm.prank(admin);
        vm.expectRevert(ISignoShield.NotPrincipal.selector);
        shield.revokeMandate(id);
    }

    function test_roles_enforcerCanOnlyFreeze() public {
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, enforcer));
        shield.setAdapter(address(adapter), false);
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, enforcer));
        shield.setEnforcer(stranger, true);
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, enforcer));
        shield.setFeeRecipient(enforcer);
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, enforcer));
        shield.setFeeBps(0);
        vm.prank(stranger);
        vm.expectRevert(ISignoShield.NotEnforcer.selector);
        shield.freezeAgent(agent);
    }

    function test_roles_freezeReachesEveryMandateTheAgentHolds() public {
        bytes32 a = _register();
        vm.prank(stranger);
        bytes32 b = shield.registerMandate(_defaultParams());
        vm.prank(enforcer);
        shield.freezeAgent(agent);
        _assertReason(a, 1, ISignoShield.MandateReason.AGENT_FROZEN);
        _assertReason(b, 1, ISignoShield.MandateReason.AGENT_FROZEN);
        // A different agent is untouched.
        ISignoShield.MandateParams memory p = _defaultParams();
        p.agent = makeAddr("agent2");
        bytes32 c = _register(p);
        _assertReason(c, 1, ISignoShield.MandateReason.OK);
    }

    function test_roles_adminAndEnforcerNeverCoincide() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdminCannotBeEnforcer.selector, admin));
        shield.setEnforcer(admin, true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdminCannotBeEnforcer.selector, enforcer));
        shield.transferOwnership(enforcer);

        vm.prank(admin);
        shield.transferOwnership(stranger);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdminCannotBeEnforcer.selector, stranger));
        shield.setEnforcer(stranger, true);

        vm.prank(stranger);
        shield.acceptOwnership();
        assertEq(shield.owner(), stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.AdminCannotBeEnforcer.selector, stranger));
        shield.setEnforcer(stranger, true);
    }

    function test_canFireBy_reportsTheCallerCheck() public {
        bytes32 id = _register();
        (bool ok, ISignoShield.MandateReason r) = shield.canFireBy(id, stranger, 1);
        assertFalse(ok);
        assertEq(uint8(r), uint8(ISignoShield.MandateReason.NOT_AGENT));
        (ok, r) = shield.canFireBy(id, agent, 1);
        assertTrue(ok);
        assertEq(uint8(r), uint8(ISignoShield.MandateReason.OK));
    }

    function test_roles_ownershipCannotBeRenounced() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "renounceOwnership"));
        shield.renounceOwnership();
        assertEq(shield.owner(), admin);
    }

    function test_roles_listingRequiresCode() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "adapter"));
        shield.setAdapter(stranger, true);
    }

    function test_constructor_requiresAConditionModule() public {
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "conditionModule"));
        new SignoShield(admin, ICondition(stranger), FEE_BPS);
    }

    // ------------------------------------------------- review fixes (FLIP-201)

    /// M-1: the Shield measures what left the principal; an adapter that keeps
    /// the tokens and reports nothing is charged for everything it took.
    function test_fire_chargesWhatLeftThePrincipal_notWhatTheAdapterReports() public {
        DishonestAdapter bad = new DishonestAdapter(address(shield));
        vm.startPrank(admin);
        shield.setAdapter(address(bad), true);
        shield.setFeeRecipient(feeSink);
        vm.stopPrank();
        ISignoShield.MandateParams memory p = _defaultParams();
        p.adapter = address(bad);
        bytes32 id = _register(p);
        uint256 before = token.balanceOf(principal);

        assertEq(_fire(id, TX_CAP), 100.1e6, "spent = measured amount + fee on it");
        assertEq(_fire(id, TX_CAP), 100.1e6);
        assertEq(shield.getMandate(id).cumulativeUsed, 200.2e6, "counter follows the measurement");
        assertEq(before - token.balanceOf(principal), 200.2e6, "principal lost exactly the counter");
        assertEq(token.balanceOf(feeSink), 0.2e6, "fee on the measured spend");
        // The lifetime cap binds on what actually left, not on the report.
        _assertReason(id, TX_CAP, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.OVER_CUMULATIVE_CAP));
        shield.fire(id, TX_CAP, "");
    }

    /// More than `amount` leaving the principal is a failure of the firing.
    function test_fire_refusesWhenMoreThanTheAmountLeftThePrincipal() public {
        GreedyAdapter greedy = new GreedyAdapter(address(shield));
        vm.prank(admin);
        shield.setAdapter(address(greedy), true);
        vm.prank(principal);
        token.approve(address(greedy), type(uint256).max); // an unrelated allowance the adapter abuses
        ISignoShield.MandateParams memory p = _defaultParams();
        p.adapter = address(greedy);
        bytes32 id = _register(p);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.SpendExceedsAmount.selector, 60e6, 50e6));
        shield.fire(id, 50e6, "");
    }

    /// L-1: the fee's worst case is out of the principal's wallet before the
    /// adapter runs, so the adapter's outcome check sees the final state, and
    /// what was not owed comes back.
    function test_fire_feeLeavesBeforeTheAdapterAndSettlesAfter() public {
        WitnessAdapter witness = new WitnessAdapter(address(shield));
        vm.startPrank(admin);
        shield.setAdapter(address(witness), true);
        shield.setFeeRecipient(feeSink);
        vm.stopPrank();
        ISignoShield.MandateParams memory p = _defaultParams();
        p.adapter = address(witness);
        bytes32 id = _register(p);

        uint256 before = token.balanceOf(principal);
        uint256 spent = _fire(id, 100e6);
        // At execute time the principal was already short the amount AND the fee's worst case.
        assertEq(witness.principalBalanceAtExecute(), before - 100e6 - 0.1e6);
        // The adapter spent half: fee on half, the rest of the worst case refunded.
        assertEq(spent, 50e6 + 0.05e6);
        assertEq(token.balanceOf(principal), before - 50e6 - 0.05e6, "unspent amount and unowed fee are back");
        assertEq(token.balanceOf(feeSink), 0.05e6);
        assertEq(token.balanceOf(address(shield)), 0, "the Shield holds nothing between transactions");
    }

    /// L-3: allowance and balance shortfalls are reason codes, before the trigger.
    function test_canFire_reportsAllowanceAndBalanceShortfalls() public {
        vm.prank(admin);
        shield.setFeeRecipient(feeSink);
        bytes32 id = _register();
        vm.prank(principal);
        token.approve(address(shield), 50e6);
        // 50e6 needs 50.05e6 with the fee.
        _assertReason(id, 50e6, ISignoShield.MandateReason.INSUFFICIENT_ALLOWANCE);
        vm.prank(admin);
        shield.setFeeRecipient(address(0));
        _assertReason(id, 50e6, ISignoShield.MandateReason.OK);
        vm.prank(principal);
        token.approve(address(shield), type(uint256).max);
        vm.prank(principal);
        token.transfer(stranger, 1_000e6 - 30e6);
        _assertReason(id, 50e6, ISignoShield.MandateReason.INSUFFICIENT_BALANCE);
        _assertReason(id, 30e6, ISignoShield.MandateReason.OK);
        vm.prank(agent);
        vm.expectRevert(_blocked(id, ISignoShield.MandateReason.INSUFFICIENT_BALANCE));
        shield.fire(id, 50e6, "");
    }

    /// L-3: a lifetime cap that cannot hold one firing at the per-firing cap plus its fee is refused.
    function test_register_rejectsLifetimeCapUnderOneFullFiringWithFee() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.maxTransactionValue = 100e6;
        p.maxCumulativeValue = 100e6;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "maxCumulativeValue"));
        shield.registerMandate(p);
        p.maxCumulativeValue = 100.1e6;
        _register(p);
    }

    /// I-2: an absurd per-firing cap is a clean rejection, never a panic.
    function test_register_absurdCapIsRejectedCleanly() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.maxTransactionValue = type(uint256).max;
        p.maxCumulativeValue = type(uint256).max;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "maxCumulativeValue"));
        shield.registerMandate(p);
    }

    /// L-4: a trigger that cannot be read is refused at registration.
    function test_register_dryRunsTheTrigger() public {
        ISignoShield.MandateParams memory p = _defaultParams();
        p.condition = _hfBelow(1e18);
        p.condition.target = stranger; // no code
        vm.prank(principal);
        vm.expectRevert();
        shield.registerMandate(p);
        p.condition.target = address(target);
        p.condition.wordOffset = 200; // past the return data
        vm.prank(principal);
        vm.expectRevert();
        shield.registerMandate(p);
        p.condition.wordOffset = 2;
        _register(p);
    }

    /// L-2: the fee can never be pointed where it could not be spent.
    function test_setFeeRecipient_rejectsTheShieldAndListedAdapters() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "feeRecipient"));
        shield.setFeeRecipient(address(shield));
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "feeRecipient"));
        shield.setFeeRecipient(address(adapter));
        shield.setFeeRecipient(feeSink);
        vm.stopPrank();
        assertEq(shield.feeRecipient(), feeSink);
    }
}

/// A listed adapter that keeps the tokens and reports nothing spent (FLIP-201 M-1).
contract DishonestAdapter is IShieldAdapter {
    address public immutable shield;
    address public constant THIEF = address(0xbad);

    constructor(address shield_) {
        shield = shield_;
    }

    function supportsAction(bytes32) external pure returns (bool) {
        return true;
    }

    function validateConfig(bytes32, address, bytes calldata) external pure {}

    function execute(Context calldata ctx, uint256 amount, bytes calldata) external returns (uint256) {
        require(msg.sender == shield, "not shield");
        IERC20(ctx.asset).transfer(THIEF, amount);
        return 0;
    }
}

/// An adapter that pulls more than the Shield gave it through an unrelated allowance.
contract GreedyAdapter is IShieldAdapter {
    address public immutable shield;

    constructor(address shield_) {
        shield = shield_;
    }

    function supportsAction(bytes32) external pure returns (bool) {
        return true;
    }

    function validateConfig(bytes32, address, bytes calldata) external pure {}

    function execute(Context calldata ctx, uint256 amount, bytes calldata) external returns (uint256) {
        require(msg.sender == shield, "not shield");
        IERC20(ctx.asset).transferFrom(ctx.principal, address(0xbad), 10e6);
        IERC20(ctx.asset).transfer(address(0xbad), amount);
        return amount;
    }
}

/// An adapter that records the principal's balance when it runs and spends half.
contract WitnessAdapter is IShieldAdapter {
    address public immutable shield;
    uint256 public principalBalanceAtExecute;

    constructor(address shield_) {
        shield = shield_;
    }

    function supportsAction(bytes32) external pure returns (bool) {
        return true;
    }

    function validateConfig(bytes32, address, bytes calldata) external pure {}

    function execute(Context calldata ctx, uint256 amount, bytes calldata) external returns (uint256) {
        require(msg.sender == shield, "not shield");
        principalBalanceAtExecute = IERC20(ctx.asset).balanceOf(ctx.principal);
        uint256 spend = amount / 2;
        IERC20(ctx.asset).transfer(address(0xdead), spend);
        IERC20(ctx.asset).transfer(ctx.principal, amount - spend);
        return spend;
    }
}

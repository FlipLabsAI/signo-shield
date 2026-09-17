// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {CompoundCondition} from "contracts/core/CompoundCondition.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

/// The evaluator is pluggable per mandate (Austin 2026-09-16: "we will
/// definitely want 'A and B' quite soon"). Listing, pinning at registration,
/// the dry-run through a compound, and delisting reaching no live mandate.
/// Same harness shape as SignoShield.t.sol, kept in its own file.
contract SignoShieldEvaluatorsTest is Test {
    SignoShield internal shield;
    ConditionModule internal conditions;
    CompoundCondition internal compound;
    MockAdapter internal adapter;
    MockERC20 internal token;
    MockTarget internal target;
    address internal admin = makeAddr("admin");
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");
    bytes32 internal constant ACTION = keccak256("mock.spend");
    uint16 internal constant FEE_BPS = 10;
    uint256 internal constant TX_CAP = 100e6;
    uint256 internal constant LIFETIME = 250e6;
    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    function setUp() public {
        vm.warp(1_800_000_000);
        conditions = new ConditionModule();
        shield = new SignoShield(admin, conditions, FEE_BPS);
        compound = new CompoundCondition(conditions);
        adapter = new MockAdapter(address(shield));
        token = new MockERC20("Mock USD", "mUSD", 6);
        target = new MockTarget();
        target.set(10, 20, 30);
        vm.prank(admin);
        shield.setAdapter(address(adapter), true);
        token.mint(principal, 1_000e6);
        vm.prank(principal);
        token.approve(address(shield), type(uint256).max);
    }

    // ------------------------------------------------------------- helpers

    function _leaf(uint8 w, uint256 threshold) internal view returns (ICondition.Condition memory) {
        return ICondition.Condition({
            target: address(target),
            callData: abi.encodeCall(MockTarget.read, ()),
            wordOffset: w,
            comparator: ICondition.Comparator.LessThan,
            threshold: threshold,
            evaluator: address(0)
        });
    }

    function _and(ICondition.Condition memory a, ICondition.Condition memory b)
        internal
        view
        returns (ICondition.Condition memory)
    {
        ICondition.Condition[] memory leaves = new ICondition.Condition[](2);
        leaves[0] = a;
        leaves[1] = b;
        return ICondition.Condition({
            target: address(compound),
            callData: abi.encode(CompoundCondition.Op.And, leaves),
            wordOffset: 0,
            comparator: ICondition.Comparator.LessThan,
            threshold: 0,
            evaluator: address(compound)
        });
    }

    function _params(ICondition.Condition memory c) internal view returns (ISignoShield.MandateParams memory p) {
        p.agent = agent;
        p.adapter = address(adapter);
        p.action = ACTION;
        p.asset = address(token);
        p.maxTransactionValue = TX_CAP;
        p.maxCumulativeValue = LIFETIME;
        p.validFrom = 0;
        p.validUntil = VALID_UNTIL;
        p.condition = c;
        p.actionConfig = "";
    }

    function _register(ISignoShield.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _list() internal {
        vm.prank(admin);
        shield.setEvaluator(address(compound), true);
    }

    function _reason(bytes32 id) internal view returns (ISignoShield.MandateReason r) {
        (, r) = shield.canFire(id, 1e6);
    }

    // -------------------------------------------------------------- listing

    function test_listing_theDefaultModuleIsAlwaysListed_andCannotBeTouched() public {
        assertTrue(shield.isEvaluatorListed(address(conditions)));
        assertFalse(shield.isEvaluatorListed(address(compound)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "evaluator"));
        shield.setEvaluator(address(conditions), false);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "evaluator"));
        shield.setEvaluator(address(0), true);
    }

    function test_listing_requiresCode_andTheOwner() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "evaluator"));
        shield.setEvaluator(stranger, true);
        vm.prank(stranger);
        vm.expectRevert();
        shield.setEvaluator(address(compound), true);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(shield));
        emit ISignoShield.EvaluatorListed(address(compound), true);
        shield.setEvaluator(address(compound), true);
        assertTrue(shield.isEvaluatorListed(address(compound)));
    }

    // --------------------------------------------------------- registration

    function test_register_refusesAnUnlistedEvaluator() public {
        ISignoShield.MandateParams memory p = _params(_and(_leaf(0, 15), _leaf(1, 25)));
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.EvaluatorNotListed.selector, address(compound)));
        shield.registerMandate(p);
    }

    function test_register_pinsTheEvaluatorIntoTheRecord() public {
        _list();
        bytes32 id = _register(_params(_and(_leaf(0, 15), _leaf(1, 25))));
        assertEq(shield.getMandate(id).condition.evaluator, address(compound));
    }

    function test_register_refusesAnEvaluatorWithNoTrigger() public {
        _list();
        ICondition.Condition memory c; // target 0 = no trigger
        c.evaluator = address(compound);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.InvalidParams.selector, "condition"));
        shield.registerMandate(_params(c));
    }

    /// The dry-run goes through the pinned evaluator, so a compound with one
    /// dead leaf is refused at signing — the leaf's own error, not a wrapper.
    function test_register_dryRunsEveryLeafOfACompound() public {
        _list();
        ICondition.Condition memory dead = _leaf(1, 25);
        dead.wordOffset = 7;
        ISignoShield.MandateParams memory p = _params(_and(_leaf(0, 15), dead));
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ConditionModule.ReturnDataTooShort.selector, 96, 7));
        shield.registerMandate(p);
    }

    function test_register_theDefaultModuleMayBePinnedExplicitly() public {
        ICondition.Condition memory c = _leaf(0, 15);
        c.evaluator = address(conditions);
        bytes32 id = _register(_params(c));
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.OK));
    }

    // ---------------------------------------------------------------- firing

    function test_fire_andMandate_firesOnlyWhenBothLeavesHold() public {
        _list();
        bytes32 id = _register(_params(_and(_leaf(0, 15), _leaf(1, 25))));
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.OK));
        vm.prank(agent);
        shield.fire(id, 1e6, "");
        target.set(16, 20, 30); // word0 crosses
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.TRIGGER_NOT_MET));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ISignoShield.MandateBlocked.selector, id, ISignoShield.MandateReason.TRIGGER_NOT_MET)
        );
        shield.fire(id, 1e6, "");
    }

    function test_fire_orMandate_firesWhenEitherLeafHolds() public {
        _list();
        ICondition.Condition memory c = _and(_leaf(0, 5), _leaf(1, 25)); // word0 false, word1 true
        ICondition.Condition[] memory leaves = new ICondition.Condition[](2);
        leaves[0] = _leaf(0, 5);
        leaves[1] = _leaf(1, 25);
        c.callData = abi.encode(CompoundCondition.Op.Or, leaves);
        bytes32 id = _register(_params(c));
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.OK));
        target.set(10, 26, 30); // now neither
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.TRIGGER_NOT_MET));
    }

    /// Delisting is for NEW registrations. The live mandate pinned its
    /// evaluator and keeps working; the next registration is refused.
    function test_delisting_reachesNoLiveMandate() public {
        _list();
        bytes32 id = _register(_params(_and(_leaf(0, 15), _leaf(1, 25))));
        vm.prank(admin);
        shield.setEvaluator(address(compound), false);
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.OK), "the live mandate still evaluates");
        vm.prank(agent);
        shield.fire(id, 1e6, "");
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.EvaluatorNotListed.selector, address(compound)));
        shield.registerMandate(_params(_and(_leaf(0, 15), _leaf(1, 25))));
    }

    // ------------------------------------------------------------- amendment

    function test_amend_toACompound_isValidatedLikeARegistration() public {
        bytes32 id = _register(_params(_leaf(0, 15)));
        ISignoShield.MandateParams memory p = _params(_and(_leaf(0, 15), _leaf(1, 25)));
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.EvaluatorNotListed.selector, address(compound)));
        shield.amendMandate(id, p);
        _list();
        vm.prank(principal);
        shield.amendMandate(id, p);
        assertEq(shield.getMandate(id).condition.evaluator, address(compound));
        assertEq(uint8(_reason(id)), uint8(ISignoShield.MandateReason.OK));
    }

    /// Review L-1: delisting reaches no live mandate on amendment either. The
    /// principal keeps its pinned evaluator and can still lower a cap or move
    /// the expiry; switching to an evaluator that is not listed is refused.
    function test_amend_keepsItsPinnedEvaluator_afterDelisting() public {
        _list();
        bytes32 id = _register(_params(_and(_leaf(0, 15), _leaf(1, 25))));
        vm.prank(admin);
        shield.setEvaluator(address(compound), false);

        ISignoShield.MandateParams memory p = _params(_and(_leaf(0, 15), _leaf(1, 25)));
        p.maxCumulativeValue = LIFETIME - 50e6;
        p.validUntil = VALID_UNTIL - 1 days;
        vm.prank(principal);
        shield.amendMandate(id, p);
        assertEq(shield.getMandate(id).maxCumulativeValue, LIFETIME - 50e6);
        assertEq(shield.getMandate(id).condition.evaluator, address(compound));

        CompoundCondition other = new CompoundCondition(conditions);
        ICondition.Condition memory switched = _and(_leaf(0, 15), _leaf(1, 25));
        switched.target = address(other);
        switched.evaluator = address(other);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ISignoShield.EvaluatorNotListed.selector, address(other)));
        shield.amendMandate(id, _params(switched));
    }

    /// Review L-3: a compound registered with outer fields set is refused at
    /// signing, so the record has one encoding.
    function test_register_refusesANonCanonicalCompound() public {
        _list();
        ICondition.Condition memory c = _and(_leaf(0, 15), _leaf(1, 25));
        c.comparator = ICondition.Comparator.GreaterThan;
        c.threshold = type(uint256).max;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(CompoundCondition.BadCompound.selector, "shape"));
        shield.registerMandate(_params(c));
    }
}

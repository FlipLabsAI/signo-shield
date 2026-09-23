// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {ClaimsConfirmationVenue} from "./V1ClaimsConfirmation.t.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// An unusual but admitted 77-decimal collateral token represents an ordinary-sized
/// position using large raw units. The read is honest; repayment removes half its backing.
contract R7CollateralMarket {
    IERC20 public immutable asset;
    IERC20 public immutable collateral;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public collateralOf;

    constructor(IERC20 a, IERC20 c) {
        asset = a;
        collateral = c;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return address(asset);
    }

    function deposit(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] = amount;
        balanceOf[msg.sender] = 1000e18;
    }

    function repay(address who, uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[who] -= amount;
        uint256 left = collateralOf[who] / 2;
        uint256 removed = collateralOf[who] - left;
        collateralOf[who] = left;
        collateral.transfer(address(0xBAD), removed);
    }
}

/// Actual core/executor/evaluator, with catalog targets returning boundary-sized values.
/// Counterexamples are not claims about reachable balances in the launch Aave market.
contract V1Round7ReadsTest is V1ReviewBase {
    uint256 internal constant TOP = uint256(type(int256).max);

    function _comparison(ExprLib.Kind op) internal view returns (bytes memory) {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] =
            ExprLib.Read(collateralId, address(market), abi.encode(principal), ExprLib.Subject.Principal, 18);
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        n[1] = ExprLib.Node(uint8(ExprLib.Kind.BEFORE), 0, 0);
        n[2] = ExprLib.Node(uint8(op), 0, 1);
        return abi.encode(r, n);
    }

    function _repayMandate() internal returns (bytes32) {
        return _register(_genericParams(generic.ACTION_REPAY(), _repayConfig()));
    }

    function _expectOutcome(bytes32 id, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, reason
            )
        );
    }

    /// Round 8: an amount above the int256 range is refused, so a halving above it can no
    /// longer read as "unchanged" (the reviewer's round 7 high, conditional).
    function test_fixHugeCollateralIsRefusedNotSaturated() public {
        market.setDebt(principal, 1000e18);
        market.setCollateral(principal, type(uint256).max);
        market.setSteal(true);
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), _repayConfig());
        p.outcome = _comparison(ExprLib.Kind.GE);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        vm.prank(principal);
        core.registerMandate(p);
    }

    function test_controlRepresentableCollateralLossStillRollsBack() public {
        market.setDebt(principal, 1000e18);
        market.setCollateral(principal, TOP);
        market.setSteal(true);
        bytes32 id = _repayMandate();
        bytes memory route = _route(_repayCall(100e18));
        _expectOutcome(
            id,
            abi.encodeWithSelector(
                GenericExecutorV1.CollateralFell.selector, type(int256).max, int256(TOP / 2)
            )
        );
        _fire(id, 100e18, route);
        assertEq(market.collateralOf(principal), TOP);
        assertEq(market.debtOf(principal), 1000e18);
        assertEq(core.getMandate(id).firings, 0);
    }

    function test_fixHighPrecisionCollateralAboveTheRangeIsRefused() public {
        MockERC20 collateral = new MockERC20("High precision collateral", "HP", 77);
        R7CollateralMarket m = new R7CollateralMarket(IERC20(address(asset)), IERC20(address(collateral)));
        collateral.mint(principal, type(uint256).max);
        vm.startPrank(principal);
        collateral.approve(address(m), type(uint256).max);
        m.deposit(type(uint256).max);
        vm.stopPrank();
        GenericExecutorV1.Config memory c = _repayConfig();
        c.market = address(m);
        c.collateralTarget = address(m);
        c.venues[0] = GenericExecutorV1.Venue(address(m), address(m));
        bytes32 id = _register(_genericParams(generic.ACTION_REPAY(), c));
        bytes memory route = _route(
            IExecutorV1.Call(
                address(m),
                address(m),
                address(asset),
                100e18,
                false,
                abi.encodeCall(R7CollateralMarket.repay, (principal, 100e18))
            )
        );
        // Refused when the collateral is read, before anything moves.
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        _fire(id, 100e18, route);
        assertEq(m.balanceOf(principal), 1000e18);
    }

    function test_fixHugeDebtIsRefusedBeforeAnythingMoves() public {
        market.setDebt(principal, type(uint256).max);
        market.setCollateral(principal, 1000e18);
        bytes32 id = _repayMandate();
        bytes memory route = _route(_repayCall(100e18));
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        _fire(id, 100e18, route);
        assertEq(market.debtOf(principal), type(uint256).max);
        assertEq(asset.balanceOf(principal), 1_000_000e18);
    }

    function test_fixDebtAboveTheRangeIsRefused() public {
        market.setDebt(principal, TOP + 50e18);
        market.setCollateral(principal, 1000e18);
        bytes32 id = _repayMandate();
        bytes memory route = _route(_repayCall(100e18));
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        _fire(id, 100e18, route);
    }

    function testFuzz_fixDistinctHighReadsAreRefused(uint128 delta) public {
        uint256 high = TOP + 1 + uint256(delta);
        market.setCollateral(principal, high);
        bytes memory tree = _comparison(ExprLib.Kind.EQ);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        evaluator.snapshot(tree, principal);
    }

    function test_fixAnOutcomeReadAboveTheRangeIsRefused() public {
        market.setCollateral(principal, TOP);
        bytes memory tree = _comparison(ExprLib.Kind.GT);
        int256[] memory before_ = evaluator.snapshot(tree, principal);
        market.setCollateral(principal, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        evaluator.judgeOutcome(tree, principal, new int256[](0), before_, 0);
    }

    function _mathTree(ExprLib.Kind op, uint256 rhs, bytes32 id) internal view returns (bytes memory) {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read(id, address(market), abi.encode(principal), ExprLib.Subject.Principal, 18);
        ExprLib.Node[] memory n = new ExprLib.Node[](5);
        n[0] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        n[1] = ExprLib.Node(uint8(ExprLib.Kind.CONST), rhs, 0);
        n[2] = ExprLib.Node(uint8(op), 0, 1);
        n[3] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 0, 0);
        n[4] = ExprLib.Node(uint8(ExprLib.Kind.GE), 2, 3);
        return abi.encode(r, n);
    }

    /// The top only exists for a descriptor that says it means "unbounded"; arithmetic on
    /// it stays checked and fails closed.
    function test_topArithmeticOverflowAndDivisionByZeroStillFailClosed() public {
        market.setCollateral(principal, type(uint256).max);
        (IDescriptors.Descriptor memory d,,) = registry.descriptorOf(collateralId);
        d.unboundedTop = true;
        bytes32 topId = registry.listDescriptor(d);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        evaluator.judgeTrigger(_mathTree(ExprLib.Kind.ADD, 1, collateralId), principal, new int256[](0), 0);
        bytes memory add = _mathTree(ExprLib.Kind.ADD, 1, topId);
        bytes memory mul = _mathTree(ExprLib.Kind.MUL, 2, topId);
        bytes memory div = _mathTree(ExprLib.Kind.DIV, 0, topId);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        evaluator.judgeTrigger(add, principal, new int256[](0), 0);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        evaluator.judgeTrigger(mul, principal, new int256[](0), 0);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        evaluator.judgeTrigger(div, principal, new int256[](0), 0);
        assertTrue(
            evaluator.judgeTrigger(_mathTree(ExprLib.Kind.SUB, 1, topId), principal, new int256[](0), 0)
        );
    }

    /// Round 8: an owed amount above the range is refused, so the reward floor can no
    /// longer be weakened by reading it as the top.
    function test_fixClaimableAboveTheRangeIsRefused() public {
        ClaimsConfirmationVenue venue = new ClaimsConfirmationVenue(reward, output);
        venue.configure(type(uint256).max, TOP, 0);
        ClaimExecutorV1.Config memory c = _claimConfig();
        IShieldRegistryV1.ClaimRule memory rule = _claimRule(address(venue));
        rule.selector = venue.collect.selector;
        c.claims[0] = registry.listClaimRule(rule);
        c.claimable[0].descriptor = registry.listDescriptor(_claimableDescriptor(address(venue)));
        c.claimable[0].target = address(venue);
        bytes32 id = _register(_claimParams(c));
        IExecutorV1.Context memory ctx;
        ctx.principal = principal;
        ctx.action = claims.ACTION_CLAIM_COLLECT();
        ctx.actionConfig = abi.encode(uint8(1), c);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        claims.snapshot(ctx, 0);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ValueOutOfRange.selector, 0));
        _fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 0);
    }
}

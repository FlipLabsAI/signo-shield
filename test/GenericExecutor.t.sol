// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";
import {DisposableClone} from "contracts/executors/DisposableClone.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockAaveOracle} from "./mocks/MockAave.sol";

/// A router that tries to fire again from inside the sandbox's call.
contract ReenteringRouter {
    GenericExecutor internal immutable executor;

    constructor(GenericExecutor executor_) {
        executor = executor_;
    }

    function attack(IShieldAdapter.Context calldata ctx) external {
        executor.execute(ctx, 1, "");
    }
}

/// A router that moves the pinned oracle in the same transaction, then pays
/// what the moved price would justify. The bound must have been fixed before.
contract OracleMovingRouter {
    using SafeERC20 for IERC20;

    MockAaveOracle internal immutable oracle;

    constructor(MockAaveOracle oracle_) {
        oracle = oracle_;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address to)
        external
    {
        oracle.set(tokenIn, 250e8); // 10x cheaper than the pinned feed said a block ago
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}

/// Tier 1 generic bounded execution (FLIP-238): the executor, its sandbox, the
/// three rate rules, every way the bound can be dodged, and the whole path
/// through the real Shield. The test contract plays the Shield in the unit
/// cases (it funds the executor and calls `execute`), and the real Shield in
/// the integration case.
contract GenericExecutorTest is Test {
    GenericExecutor internal executor;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockERC20 internal tokenOut18;
    MockRouter internal router;
    MockAaveOracle internal oracle;

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal attacker = makeAddr("attacker");
    bytes32 internal constant MANDATE = keccak256("mandate-1");
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");
    bytes32 internal constant TRANSFER = keccak256("generic.transfer");

    function setUp() public {
        tokenIn = new MockERC20("In", "IN", 18);
        tokenOut = new MockERC20("Out", "OUT", 6);
        tokenOut18 = new MockERC20("Out18", "OUT18", 18);
        router = new MockRouter();
        oracle = new MockAaveOracle();
        executor = new GenericExecutor(address(this));
        tokenOut.mint(address(router), 1_000_000e6);
        tokenOut18.mint(address(router), 1_000_000e18);
    }

    // ------------------------------------------------------------- helpers

    function _floorCfg(uint256 floor) internal view returns (bytes memory) {
        return abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(tokenOut),
                target: address(router),
                spender: address(router),
                rateKind: GenericExecutor.RateKind.Floor,
                oracle: address(0),
                rateOrFloor: floor,
                maxSlippageBps: 0
            })
        );
    }

    function _oracleCfg(uint16 slippageBps) internal view returns (bytes memory) {
        return abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(tokenOut),
                target: address(router),
                spender: address(router),
                rateKind: GenericExecutor.RateKind.Oracle,
                oracle: address(oracle),
                rateOrFloor: 0,
                maxSlippageBps: slippageBps
            })
        );
    }

    function _fixedCfg(uint256 rate) internal view returns (bytes memory) {
        return abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(tokenOut18),
                target: address(router),
                spender: address(router),
                rateKind: GenericExecutor.RateKind.Fixed,
                oracle: address(0),
                rateOrFloor: rate,
                maxSlippageBps: 0
            })
        );
    }

    function _ctx(bytes32 action, bytes memory cfg) internal view returns (IShieldAdapter.Context memory) {
        return IShieldAdapter.Context({
            mandateId: MANDATE,
            principal: principal,
            agent: agent,
            action: action,
            asset: address(tokenIn),
            actionConfig: cfg
        });
    }

    /// The Shield's half of a firing: the amount arrives at the executor first.
    function _fund(uint256 amount) internal {
        tokenIn.mint(address(executor), amount);
    }

    function _fire(bytes memory cfg, uint256 amount, bytes memory data) internal returns (uint256) {
        _fund(amount);
        return executor.execute(_ctx(TRANSFORM, cfg), amount, data);
    }

    /// A firing that must revert: fund first, then the cheatcode, then the one call.
    function _fireExpecting(bytes memory cfg, uint256 amount, bytes memory data, bytes memory revertData)
        internal
    {
        _fund(amount);
        IShieldAdapter.Context memory ctx = _ctx(TRANSFORM, cfg);
        if (revertData.length == 0) vm.expectRevert();
        else vm.expectRevert(revertData);
        executor.execute(ctx, amount, data);
    }

    function _swap(uint256 amountIn, address out, uint256 amountOut, address to)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(MockRouter.swap, (address(tokenIn), amountIn, out, amountOut, to));
    }

    // ------------------------------------------------------------ transform

    function test_transform_floor_paysTheOwnerAndReportsTheMeasuredSpend() public {
        address clone = executor.nextClone(MANDATE);
        bytes memory data = _swap(1e18, address(tokenOut), 2500e6, clone);
        IShieldAdapter.Context memory ctx = _ctx(TRANSFORM, _floorCfg(2400e6));
        _fund(1e18);
        vm.expectEmit(true, true, true, true, address(executor));
        emit GenericExecutor.Transformed(
            MANDATE, principal, address(tokenIn), address(tokenOut), clone, 1e18, 2500e6, 2400e6
        );
        uint256 spent = executor.execute(ctx, 1e18, data);
        assertEq(spent, 1e18);
        assertEq(tokenOut.balanceOf(principal), 2500e6, "output landed with the owner");
        assertEq(tokenIn.balanceOf(principal), 0);
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor holds nothing");
        assertEq(tokenIn.balanceOf(clone), 0, "sandbox holds nothing");
        assertEq(tokenOut.balanceOf(clone), 0);
        assertEq(tokenIn.allowance(clone, address(router)), 0, "no approval survives");
        assertEq(executor.firings(MANDATE), 1);
    }

    function test_transform_outputBelowTheBoundReverts() public {
        address clone = executor.nextClone(MANDATE);
        _fireExpecting(
            _floorCfg(2600e6),
            1e18,
            _swap(1e18, address(tokenOut), 2500e6, clone),
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, 2500e6, 2600e6)
        );
    }

    function test_transform_outputPaidToAThirdPartyDoesNotCount() public {
        _fireExpecting(
            _floorCfg(2400e6),
            1e18,
            _swap(1e18, address(tokenOut), 2500e6, attacker),
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, 0, 2400e6)
        );
    }

    function test_transform_partialSaleReturnsTheRestAndChargesWhatWasSold() public {
        address clone = executor.nextClone(MANDATE);
        uint256 spent = _fire(_floorCfg(900e6), 1e18, _swap(0.4e18, address(tokenOut), 1000e6, clone));
        assertEq(spent, 0.4e18, "only what the route took counts");
        assertEq(tokenIn.balanceOf(principal), 0.6e18, "the unsold part is back with the owner");
        assertEq(tokenOut.balanceOf(principal), 1000e6);
    }

    function test_transform_nothingSoldReverts() public {
        _fireExpecting(
            _floorCfg(1),
            1e18,
            _swap(0, address(tokenOut), 0, principal),
            abi.encodeWithSelector(GenericExecutor.NothingSold.selector)
        );
    }

    function test_transform_freshSandboxEveryFiring_andPredictable() public {
        address first = executor.nextClone(MANDATE);
        _fire(_floorCfg(1), 1e18, _swap(1e18, address(tokenOut), 100e6, first));
        address second = executor.nextClone(MANDATE);
        assertTrue(first != second, "a new sandbox per firing");
        assertTrue(first.code.length != 0 && second.code.length == 0, "the next one does not exist yet");
        _fire(_floorCfg(1), 1e18, _swap(1e18, address(tokenOut), 100e6, second));
        assertTrue(second.code.length != 0);
        // A used sandbox cannot run again, even for its executor.
        vm.prank(address(executor));
        vm.expectRevert(DisposableClone.AlreadyUsed.selector);
        DisposableClone(first)
            .run(address(router), address(router), address(tokenIn), 0, "", address(tokenOut), principal);
        // And nobody else can run one at all.
        vm.expectRevert(DisposableClone.NotExecutor.selector);
        DisposableClone(second)
            .run(address(router), address(router), address(tokenIn), 0, "", address(tokenOut), principal);
    }

    function test_transform_calldataCannotLeaveTheSurface() public {
        // The target is pinned: calldata meant for the token (an approve to the
        // attacker) hits the router, which has no such function, and the whole
        // firing reverts with the sandbox's error.
        bytes memory data = abi.encodeCall(IERC20.approve, (attacker, type(uint256).max));
        _fireExpecting(_floorCfg(1), 1e18, data, "");
        assertEq(tokenIn.allowance(executor.nextClone(MANDATE), attacker), 0);
    }

    function test_transform_reenteringTheExecutorFromTheSandboxFails() public {
        ReenteringRouter evil = new ReenteringRouter(executor);
        bytes memory cfg = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(tokenOut),
                target: address(evil),
                spender: address(evil),
                rateKind: GenericExecutor.RateKind.Floor,
                oracle: address(0),
                rateOrFloor: 1,
                maxSlippageBps: 0
            })
        );
        _fireExpecting(cfg, 1e18, abi.encodeCall(ReenteringRouter.attack, (_ctx(TRANSFORM, cfg))), "");
    }

    function test_transform_oracleRateBoundsTheOutput() public {
        oracle.set(address(tokenIn), 2500e8);
        oracle.set(address(tokenOut), 1e8);
        // Fair: 1 IN = 2500 OUT; 1 % slippage => 2475 OUT minimum.
        address clone = executor.nextClone(MANDATE);
        _fire(_oracleCfg(100), 1e18, _swap(1e18, address(tokenOut), 2480e6, clone));
        assertEq(tokenOut.balanceOf(principal), 2480e6);
        clone = executor.nextClone(MANDATE);
        _fireExpecting(
            _oracleCfg(100),
            1e18,
            _swap(1e18, address(tokenOut), 2470e6, clone),
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, 2470e6, 2475e6)
        );
    }

    /// A one-wei sale under a fixed rate computes exact = 1, slack = 1, bound = 0.
    /// Before the floor of one unit, a route that took the wei and returned
    /// nothing passed the post-condition. Review finding, 2026-09-16.
    function test_transform_dustSaleForNothingIsRefused() public {
        _fireExpecting(
            _fixedCfg(1e18),
            1,
            _swap(1, address(tokenOut18), 0, principal), // takes the wei, pays nothing
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, 0, 1)
        );
    }

    /// Review finding M-1 (2026-09-16): anyone could send tokenIn to the
    /// predicted sandbox; the sweep returned it to the owner, "returned" swallowed
    /// the sale, every firing read NothingSold and the counter never moved.
    /// Parked tokens are the owner's windfall, never this firing's refund.
    function test_transform_parkedTokenInAtThePredictedSandboxDoesNotBrickTheMandate() public {
        address clone = executor.nextClone(MANDATE);
        tokenIn.mint(clone, 1e18); // a stranger parks a full firing's worth
        // A full sale at the amount: charged in full, the owner gets the output and the parked tokens.
        uint256 spent = _fire(_floorCfg(1), 1e18, _swap(1e18, address(tokenOut), 100e6, clone));
        assertEq(spent, 1e18, "the sale is charged, not hidden by the parked refund");
        assertEq(tokenIn.balanceOf(principal), 1e18, "the parked tokens land with the owner");
        assertEq(tokenOut.balanceOf(principal), 100e6);
        assertTrue(executor.nextClone(MANDATE) != clone, "the counter moved on");
        // A partial sale with more parked: only what was sold is charged.
        clone = executor.nextClone(MANDATE);
        tokenIn.mint(clone, 5e18);
        spent = _fire(_floorCfg(1), 1e18, _swap(0.4e18, address(tokenOut), 40e6, clone));
        assertEq(spent, 0.4e18);
        assertEq(tokenIn.balanceOf(principal), 1e18 + 5e18 + 0.6e18);
    }

    /// Review finding L-2: the oracle is read before the agent's call, so a
    /// feed the route can move in the same transaction bounds nothing less.
    function test_transform_oracleIsReadBeforeTheCall() public {
        oracle.set(address(tokenIn), 2500e8);
        oracle.set(address(tokenOut), 1e8);
        OracleMovingRouter mover = new OracleMovingRouter(oracle);
        tokenOut.mint(address(mover), 1_000_000e6);
        GenericExecutor.TransformConfig memory c =
            abi.decode(_oracleCfg(100), (GenericExecutor.TransformConfig));
        c.target = address(mover);
        c.spender = address(mover);
        address clone = executor.nextClone(MANDATE);
        // 250 OUT would satisfy the moved price (247.5 min); the pinned one wants 2475.
        _fireExpecting(
            abi.encode(c),
            1e18,
            abi.encodeCall(
                OracleMovingRouter.swap, (address(tokenIn), 1e18, address(tokenOut), 250e6, clone)
            ),
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, 250e6, 2475e6)
        );
    }

    /// Review finding I-1: one division, so the bound is short by at most one
    /// unit of the output token (was: one unit of oracle value, 1e10 wei here).
    function test_transform_oracleBoundIsOneDivision() public {
        oracle.set(address(tokenIn), 2500e8);
        oracle.set(address(tokenOut18), 1e8);
        GenericExecutor.TransformConfig memory c =
            abi.decode(_oracleCfg(100), (GenericExecutor.TransformConfig));
        c.tokenOut = address(tokenOut18);
        // 3,999,999 wei at 2500:1 = 9,999,997,500 wei fair; 1 % under = 9,899,997,525.
        uint256 minOut = 9_899_997_525;
        address clone = executor.nextClone(MANDATE);
        _fireExpecting(
            abi.encode(c),
            3_999_999,
            _swap(3_999_999, address(tokenOut18), minOut - 1, clone),
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, minOut - 1, minOut)
        );
        clone = executor.nextClone(MANDATE);
        _fire(abi.encode(c), 3_999_999, _swap(3_999_999, address(tokenOut18), minOut, clone));
        assertEq(tokenOut18.balanceOf(principal), minOut);
    }

    function test_transform_fixedRateIsExactUpToRounding() public {
        // One basis point plus one unit of slack: real 1:1 receipts mint a wei short.
        uint256 minOut = 1e18 - (1e18 / 10_000 + 1);
        address clone = executor.nextClone(MANDATE);
        _fire(_fixedCfg(1e18), 1e18, _swap(1e18, address(tokenOut18), 1e18 - 1, clone));
        assertEq(tokenOut18.balanceOf(principal), 1e18 - 1);
        clone = executor.nextClone(MANDATE);
        _fireExpecting(
            _fixedCfg(1e18),
            1e18,
            _swap(1e18, address(tokenOut18), minOut - 1, clone),
            abi.encodeWithSelector(GenericExecutor.OutputBelowMinimum.selector, minOut - 1, minOut)
        );
    }

    function test_execute_onlyTheShield() public {
        IShieldAdapter.Context memory ctx = _ctx(TRANSFORM, _floorCfg(1));
        vm.prank(attacker);
        vm.expectRevert(GenericExecutor.NotShield.selector);
        executor.execute(ctx, 1, "");
    }

    // ------------------------------------------------------------- transfer

    function test_transfer_paysThePinnedRecipientOnly() public {
        bytes memory cfg = abi.encode(GenericExecutor.TransferConfig({recipient: attacker}));
        IShieldAdapter.Context memory ctx = _ctx(TRANSFER, cfg);
        tokenIn.mint(address(executor), 5e18);
        vm.expectEmit(true, true, true, true, address(executor));
        emit GenericExecutor.Transferred(MANDATE, principal, address(tokenIn), attacker, 5e18);
        uint256 spent = executor.execute(ctx, 5e18, "");
        assertEq(spent, 5e18);
        assertEq(tokenIn.balanceOf(attacker), 5e18);
        tokenIn.mint(address(executor), 1);
        vm.expectRevert(GenericExecutor.UnexpectedData.selector);
        executor.execute(ctx, 1, hex"01");
    }

    // ------------------------------------------------------- validateConfig

    function _expectInvalid(bytes32 action, bytes memory cfg, string memory field) internal {
        vm.expectRevert(abi.encodeWithSelector(GenericExecutor.ConfigInvalid.selector, field));
        executor.validateConfig(action, address(tokenIn), cfg);
    }

    function test_validateConfig_refusesWhatItCouldNotEnforce() public {
        bytes32 T = TRANSFORM;
        GenericExecutor.TransformConfig memory c = abi.decode(_floorCfg(1), (GenericExecutor.TransformConfig));
        executor.validateConfig(T, address(tokenIn), abi.encode(c));

        c.tokenOut = address(tokenIn);
        _expectInvalid(T, abi.encode(c), "tokenOut");
        c.tokenOut = address(executor);
        _expectInvalid(T, abi.encode(c), "tokenOut");
        c.tokenOut = executor.cloneTemplate();
        _expectInvalid(T, abi.encode(c), "tokenOut");
        c.tokenOut = address(this); // the Shield
        _expectInvalid(T, abi.encode(c), "tokenOut");
        c.tokenOut = address(router); // code, but no balanceOf
        _expectInvalid(T, abi.encode(c), "tokenOut");
        c.tokenOut = address(tokenOut);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutor.ConfigInvalid.selector, "asset"));
        executor.validateConfig(T, address(router), abi.encode(c));
        c.target = address(tokenIn);
        _expectInvalid(T, abi.encode(c), "target");
        c.target = address(this); // the Shield
        _expectInvalid(T, abi.encode(c), "target");
        c.target = attacker; // no code
        _expectInvalid(T, abi.encode(c), "target");
        c.target = address(router);
        c.spender = address(executor);
        _expectInvalid(T, abi.encode(c), "spender");
        c.spender = executor.cloneTemplate();
        _expectInvalid(T, abi.encode(c), "spender");
        c.spender = address(router);
        c.rateOrFloor = 0;
        _expectInvalid(T, abi.encode(c), "floor");
        c.rateKind = GenericExecutor.RateKind.Fixed;
        _expectInvalid(T, abi.encode(c), "rate");
        c.rateOrFloor = executor.MAX_FIXED_RATE() + 1; // would panic in the bound for any real amount
        _expectInvalid(T, abi.encode(c), "rate");
        c.rateOrFloor = executor.MAX_FIXED_RATE();
        executor.validateConfig(T, address(tokenIn), abi.encode(c));
        c.rateOrFloor = 0;
        c.rateKind = GenericExecutor.RateKind.Oracle;
        c.maxSlippageBps = 50;
        _expectInvalid(T, abi.encode(c), "oracle");
        c.oracle = address(oracle);
        c.maxSlippageBps = 0;
        _expectInvalid(T, abi.encode(c), "maxSlippageBps");
        c.maxSlippageBps = 1_001;
        _expectInvalid(T, abi.encode(c), "maxSlippageBps");
        c.maxSlippageBps = 50;
        _expectInvalid(T, abi.encode(c), "oracle:in");
        oracle.set(address(tokenIn), 1e8);
        _expectInvalid(T, abi.encode(c), "oracle:out");
        oracle.set(address(tokenOut), 1e8);
        executor.validateConfig(T, address(tokenIn), abi.encode(c));

        bytes32 X = TRANSFER;
        _expectInvalid(X, abi.encode(GenericExecutor.TransferConfig({recipient: address(0)})), "recipient");
        _expectInvalid(
            X, abi.encode(GenericExecutor.TransferConfig({recipient: address(tokenIn)})), "recipient"
        );
        _expectInvalid(X, abi.encode(GenericExecutor.TransferConfig({recipient: address(this)})), "recipient");
        _expectInvalid(
            X, abi.encode(GenericExecutor.TransferConfig({recipient: executor.cloneTemplate()})), "recipient"
        );
        executor.validateConfig(
            X, address(tokenIn), abi.encode(GenericExecutor.TransferConfig({recipient: attacker}))
        );

        vm.expectRevert(abi.encodeWithSelector(GenericExecutor.UnsupportedAction.selector, keccak256("x")));
        executor.validateConfig(keccak256("x"), address(tokenIn), "");
    }

    // -------------------------------------------------- through the Shield

    function test_throughTheRealShield_swapMandateFiresWithFeeAndBudget() public {
        address admin = makeAddr("admin");
        address feeSink = makeAddr("feeSink");
        ConditionModule conditions = new ConditionModule();
        SignoShield shield = new SignoShield(admin, conditions, 10);
        GenericExecutor ex = new GenericExecutor(address(shield));
        vm.startPrank(admin);
        shield.setAdapter(address(ex), true);
        shield.setFeeRecipient(feeSink);
        vm.stopPrank();
        tokenIn.mint(principal, 10e18);
        vm.prank(principal);
        tokenIn.approve(address(shield), type(uint256).max);

        ISignoShield.MandateParams memory p;
        p.agent = agent;
        p.adapter = address(ex);
        p.action = ex.ACTION_TRANSFORM();
        p.asset = address(tokenIn);
        p.maxTransactionValue = 1e18;
        p.maxCumulativeValue = 3e18;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.condition = ICondition.Condition({
            target: address(0),
            callData: "",
            wordOffset: 0,
            comparator: ICondition.Comparator.LessThan,
            threshold: 0
        });
        p.actionConfig = _floorCfg(2400e6);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);

        address clone = ex.nextClone(id);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 1e18, _swap(1e18, address(tokenOut), 2500e6, clone));
        assertEq(spent, 1e18 + 0.001e18, "amount plus the 10 bps fee");
        assertEq(tokenOut.balanceOf(principal), 2500e6);
        assertEq(tokenIn.balanceOf(principal), 10e18 - 1e18 - 0.001e18);
        assertEq(tokenIn.balanceOf(feeSink), 0.001e18);
        assertEq(shield.getMandate(id).cumulativeUsed, 1.001e18);
        assertEq(tokenIn.balanceOf(address(shield)), 0);
        assertEq(tokenIn.balanceOf(address(ex)), 0);

        // The agent asks for more than the route delivers against the floor: refused, nothing moves.
        clone = ex.nextClone(id);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 1e18, _swap(1e18, address(tokenOut), 2000e6, clone));
        assertEq(shield.getMandate(id).cumulativeUsed, 1.001e18, "a reverted firing charges nothing");
    }
}

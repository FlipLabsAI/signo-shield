// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRouter} from "../mocks/MockRouter.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {MockAaveOracle, MockAddressesProvider, MockDataProvider} from "../mocks/MockAave.sol";

/// Counterexample venue, NOT a claim about any deployed OKX/LiFi implementation.
contract OwnerAllowanceVenue {
    IERC20 internal immutable input;
    IERC20 internal immutable output;
    IERC20 internal immutable other;
    address internal immutable principal;
    address internal immutable thief;

    constructor(IERC20 i, IERC20 o, IERC20 x, address p, address t) {
        input = i;
        output = o;
        other = x;
        principal = p;
        thief = t;
    }

    function tradeAndPull(uint256 sold, uint256 bought, uint256 stolen) external {
        require(input.transferFrom(msg.sender, address(this), sold));
        require(other.transferFrom(principal, thief, stolen));
        require(output.transfer(msg.sender, bought));
    }
}

contract SignedWordReader {
    function negativePrice() external pure returns (int256) {
        return -1;
    }
}

/// Same ABI as ICondition, deliberately writes to expose the STATICCALL boundary.
contract StatefulBaselineEvaluator {
    uint256 public snapshots;

    function isMet(ICondition.Condition calldata) external returns (bool) {
        snapshots++;
        return true;
    }
}

contract ExpensiveView {
    function read(uint256 iterations) external pure returns (uint256 value) {
        for (uint256 i; i < iterations; i++) {
            value = uint256(keccak256(abi.encode(value, i)));
        }
    }
}

contract AdminControlledEnforcer {
    address internal immutable controller = msg.sender;

    function freeze(SignoShield shield, address agent) external {
        require(msg.sender == controller);
        shield.freezeAgent(agent);
    }
}

contract ReviewWithdrawPool {
    address public immutable ADDRESSES_PROVIDER;

    constructor(address provider) {
        ADDRESSES_PROVIDER = provider;
    }

    function withdraw(address asset, uint256, address recipient) external returns (uint256 amount) {
        amount = IERC20(asset).balanceOf(address(this));
        require(IERC20(asset).transfer(recipient, amount));
    }
}

contract ReviewSwapHarness is AaveV3Adapter {
    constructor(address shield_, IPool pool_) AaveV3Adapter(shield_, pool_) {}

    function runSwap(RepayWithCollateralConfig memory c, address p, bytes calldata data)
        external
        returns (uint256 sold, uint256 received)
    {
        return _withdrawAndSwap(c, p, data);
    }
}

/// Conditional oracle threat only: actual X Layer Aave oracle write access is NOT assumed.
contract MovingPriceVenue {
    MockAaveOracle internal immutable oracle;
    IERC20 internal immutable input;
    IERC20 internal immutable output;

    constructor(MockAaveOracle o, IERC20 i, IERC20 t) {
        oracle = o;
        input = i;
        output = t;
    }

    function swap(uint256 sold, uint256 bought) external {
        require(input.transferFrom(msg.sender, address(this), sold));
        oracle.set(address(input), 1e8);
        require(output.transfer(msg.sender, bought));
    }
}

contract FLIP270ReviewTest is Test {
    SignoShield internal shield;
    ConditionModule internal reader;
    GenericExecutor internal executor;
    MockERC20 internal input;
    MockERC20 internal output;
    MockERC20 internal other;
    MockRouter internal router;
    address internal principal = makeAddr("review-principal");
    address internal agent = makeAddr("review-agent");
    address internal thief = makeAddr("review-thief");
    address internal feeCollector = makeAddr("review-fee-collector");

    function setUp() public {
        reader = new ConditionModule();
        shield = new SignoShield(address(this), reader, 10);
        executor = new GenericExecutor(address(shield));
        shield.setAdapter(address(executor), true);
        input = new MockERC20("Input", "IN", 18);
        output = new MockERC20("Output", "OUT", 18);
        other = new MockERC20("Unmeasured asset", "OTHER", 18);
        router = new MockRouter();
        input.mint(principal, 10_000e18);
        other.mint(principal, 1_000e18);
        output.mint(address(router), 10_000e18);
        vm.prank(principal);
        input.approve(address(shield), type(uint256).max);
    }

    function _params(address venue, uint256 floor)
        internal
        view
        returns (ISignoShield.MandateParams memory p)
    {
        p.agent = agent;
        p.adapter = address(executor);
        p.action = executor.ACTION_TRANSFORM();
        p.asset = address(input);
        p.maxTransactionValue = 1_000e18;
        p.maxCumulativeValue = 10_000e18;
        p.validUntil = uint48(block.timestamp + 1 days);
        p.actionConfig = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: address(output),
                target: venue,
                spender: venue,
                rateKind: GenericExecutor.RateKind.Floor,
                oracle: address(0),
                rateOrFloor: floor,
                maxSlippageBps: 0
            })
        );
    }

    function _register(ISignoShield.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _swap(bytes32 id, uint256 bought) internal view returns (bytes memory) {
        return abi.encodeCall(
            MockRouter.swap, (address(input), 100e18, address(output), bought, executor.nextClone(id))
        );
    }

    function test_priorOwnerApprovalAllowsThirdAssetTheftDespitePassingOutcome() public {
        OwnerAllowanceVenue venue = new OwnerAllowanceVenue(input, output, other, principal, thief);
        output.mint(address(venue), 200e18);
        // The principal granted this allowance BEFORE the Shield firing.
        vm.prank(principal);
        other.approve(address(venue), 1_000e18);
        bytes32 id = _register(_params(address(venue), 100e18));
        vm.prank(agent);
        uint256 charged = shield.fire(
            id, 100e18, abi.encodeCall(OwnerAllowanceVenue.tradeAndPull, (100e18, 100e18, 1_000e18))
        );
        assertEq(charged, 100e18, "core only charges the mandate asset");
        assertEq(output.balanceOf(principal), 100e18, "required outcome passed on principal");
        assertEq(other.balanceOf(principal), 0, "unmeasured principal asset was taken");
        assertEq(other.balanceOf(thief), 1_000e18, "thief received a token clone never held");
        emit log_named_uint("other_asset_stolen", other.balanceOf(thief));
    }

    function test_failedOutcomeRollsBackPullFeeBudgetCloneAndAllowance() public {
        shield.setFeeRecipient(feeCollector);
        bytes32 id = _register(_params(address(router), 200e18));
        address clone = executor.nextClone(id);
        uint256 original = input.balanceOf(principal);
        uint256 allowanceBefore = input.allowance(principal, address(shield));
        bytes memory data = _swap(id, 100e18);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, data);
        assertEq(input.balanceOf(principal), original);
        assertEq(output.balanceOf(principal), 0);
        assertEq(input.balanceOf(address(router)), 0);
        assertEq(input.balanceOf(feeCollector), 0);
        assertEq(input.allowance(principal, address(shield)), allowanceBefore);
        assertEq(shield.getMandate(id).cumulativeUsed, 0);
        assertEq(executor.firings(id), 0);
        assertEq(clone.code.length, 0, "CREATE2 deployment rolled back");
        assertEq(input.allowance(clone, address(router)), 0);
    }

    function test_feeAtInclusionIsNotBoundBySignedMandateParams() public {
        shield.setFeeRecipient(feeCollector);
        uint256 displayedFeeBps = shield.feeBps();
        ISignoShield.MandateParams memory signedParams = _params(address(router), 100e18);
        // Same calldata; admin changes the rate before registration is included.
        shield.setFeeBps(1_000);
        bytes32 id = _register(signedParams);
        assertEq(displayedFeeBps, 10);
        assertEq(shield.getMandate(id).feeBps, 1_000);
        bytes memory data = _swap(id, 100e18);
        vm.prank(agent);
        uint256 charged = shield.fire(id, 100e18, data);
        assertEq(charged, 110e18);
        assertEq(input.balanceOf(feeCollector), 10e18);
        emit log_named_uint("displayed_fee_bps", displayedFeeBps);
        emit log_named_uint("registered_fee_bps", shield.getMandate(id).feeBps);
    }

    function test_negativeSignedOracleWordPassesUnsignedAboveThreshold() public {
        SignedWordReader source = new SignedWordReader();
        ICondition.Condition memory c = ICondition.Condition({
            target: address(source),
            callData: abi.encodeCall(SignedWordReader.negativePrice, ()),
            wordOffset: 0,
            comparator: ICondition.Comparator.GreaterThan,
            threshold: 100,
            evaluator: address(0)
        });
        assertLt(source.negativePrice(), 0);
        assertTrue(reader.isMet(c), "int256(-1) is interpreted as uint256 max");
    }

    function test_registrationViewHookCannotStoreBaseline() public {
        StatefulBaselineEvaluator stateful = new StatefulBaselineEvaluator();
        shield.setEvaluator(address(stateful), true);
        ISignoShield.MandateParams memory p = _params(address(router), 100e18);
        p.condition.target = address(stateful);
        p.condition.callData = hex"12345678";
        p.condition.evaluator = address(stateful);
        vm.prank(principal);
        vm.expectRevert();
        shield.registerMandate{gas: 300_000}(p);
        assertEq(stateful.snapshots(), 0);
        assertEq(shield.nonces(principal), 0);
    }

    function test_oneReadCanExhaustEvaluationGasDespiteOneNode() public {
        ExpensiveView source = new ExpensiveView();
        ICondition.Condition memory c = ICondition.Condition({
            target: address(source),
            callData: abi.encodeCall(ExpensiveView.read, (10_000)),
            wordOffset: 0,
            comparator: ICondition.Comparator.GreaterThanOrEqual,
            threshold: 0,
            evaluator: address(0)
        });
        vm.expectRevert();
        reader.isMet{gas: 50_000}(c);
    }

    function test_noInputClaimCannotPassCoreCheck() public {
        bytes32 id = _register(_params(address(router), 1));
        (bool ok, ISignoShield.MandateReason reason) = shield.canFire(id, 0);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISignoShield.MandateReason.ZERO_AMOUNT));
    }

    function test_adminCanFreezeThroughItsOwnAppointedEnforcer() public {
        bytes32 id = _register(_params(address(router), 100e18));
        (bool before_,) = shield.canFire(id, 100e18);
        assertTrue(before_);
        AdminControlledEnforcer forwarder = new AdminControlledEnforcer();
        shield.setEnforcer(address(forwarder), true);
        forwarder.freeze(shield, agent);
        (bool after_, ISignoShield.MandateReason reason) = shield.canFire(id, 100e18);
        assertFalse(after_);
        assertEq(uint256(reason), uint256(ISignoShield.MandateReason.AGENT_FROZEN));
    }

    function test_aaveSwapUsesOracleAfterTheRouteNotBefore() public {
        MockAaveOracle oracle = new MockAaveOracle();
        MockDataProvider dp = new MockDataProvider();
        MockAddressesProvider provider = new MockAddressesProvider(address(oracle), address(dp));
        ReviewWithdrawPool pool = new ReviewWithdrawPool(address(provider));
        ReviewSwapHarness adapter = new ReviewSwapHarness(address(this), IPool(address(pool)));
        MovingPriceVenue venue = new MovingPriceVenue(oracle, input, output);
        oracle.set(address(input), 100e8);
        oracle.set(address(output), 1e8);
        input.mint(address(pool), 10e18);
        output.mint(address(venue), 10e18);
        AaveV3Adapter.RepayWithCollateralConfig memory c = AaveV3Adapter.RepayWithCollateralConfig({
            collateral: address(input),
            debtAsset: address(output),
            targetHealthFactor: 1e18,
            maxSlippageBps: 50,
            router: address(venue),
            spender: address(venue)
        });
        (uint256 sold, uint256 received) =
            adapter.runSwap(c, principal, abi.encodeCall(MovingPriceVenue.swap, (10e18, 10e18)));
        assertEq(sold, 10e18);
        assertEq(received, 10e18);
        uint256 minimumAtPreRoutePrice = 995e18;
        assertLt(received, minimumAtPreRoutePrice, "99% below initial fair value but swap check passes");
    }

    function test_emptyTriggerAllowsTwoFiringsAtSameTimestamp() public {
        bytes32 id = _register(_params(address(router), 100e18));
        uint256 timestamp = block.timestamp;
        bytes memory first = _swap(id, 100e18);
        vm.prank(agent);
        shield.fire(id, 100e18, first);
        bytes memory second = _swap(id, 100e18);
        vm.prank(agent);
        shield.fire(id, 100e18, second);
        assertEq(block.timestamp, timestamp);
        assertEq(shield.getMandate(id).cumulativeUsed, 200e18);
        assertEq(executor.firings(id), 2);
    }

    /// Minimal model of the proposed projection, NOT production compiler code.
    function test_naiveUnknownTrueProjectionTightensNestedNegation() public pure {
        bool readable = false;
        bool unreadable = false;
        bool full = !(readable || unreadable);
        bool naiveProjection = !(readable || true);
        assertTrue(full);
        assertFalse(naiveProjection);
    }

    /// Polarity-aware abstract interpretation: lower => full => upper.
    /// Leaves 0..3 are readable; 4..7 are unreadable. Trees have depth <= 3.
    function _eval(uint256 seed, uint8 depth, uint8 truths, bool project, bool upper)
        internal
        pure
        returns (bool)
    {
        if (depth == 0) {
            uint256 leaf = seed % 8;
            if (project && leaf >= 4) return upper;
            return ((uint256(truths) >> leaf) & 1) != 0;
        }
        uint256 op = seed % 3;
        if (op == 2) return !_eval(seed >> 2, depth - 1, truths, project, !upper);
        bool a = _eval(seed >> 2, depth - 1, truths, project, upper);
        bool b = _eval(seed >> 17, depth - 1, truths, project, upper);
        return op == 0 ? a && b : a || b;
    }

    function testFuzz_polarityAwareProjectionNeverTightens(uint256 seed, uint8 truths) public pure {
        bool full = _eval(seed, 3, truths, false, true);
        bool upper = _eval(seed, 3, truths, true, true);
        bool lower = _eval(seed, 3, truths, true, false);
        assertTrue(!full || upper, "full implies projected upper condition");
        assertTrue(!lower || full, "lower approximation implies full condition");
    }
}

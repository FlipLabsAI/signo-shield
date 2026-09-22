// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {ClaimExecutorV1} from "contracts/v1/ClaimExecutorV1.sol";
import {MockToken} from "./mocks/MockExecutor.sol";
import {MockDex, MockOracle, MockDistributor} from "./mocks/MockVenues.sol";

contract ClaimExecutorV1Test is Test {
    ShieldV1 internal shield;
    ExpressionEvaluator internal ev;
    ClaimExecutorV1 internal exec;
    MockToken internal reward;
    MockToken internal weth;
    MockDistributor internal dist;
    MockDex internal dex;
    MockOracle internal oracle;

    address internal admin = address(0xAD);
    address internal principal = address(0xA11CE);
    address internal agent = address(0xA6E);
    bytes32 internal constant COLLECT = keccak256("claim.collect");
    bytes32 internal constant COMPOSE = keccak256("claim.compose");

    function setUp() public {
        shield = new ShieldV1(admin, 0);
        ev = new ExpressionEvaluator(shield);
        exec = new ClaimExecutorV1(address(shield));
        reward = new MockToken();
        weth = new MockToken();
        dist = new MockDistributor(reward);
        dex = new MockDex();
        oracle = new MockOracle();
        oracle.set(address(reward), 1e8);
        oracle.set(address(weth), 1e8);
        vm.startPrank(admin);
        shield.setExecutor(address(exec), true);
        shield.setEvaluator(address(ev), true);
        vm.stopPrank();
        dist.setOwed(principal, 100e18);
    }

    function _cfg(bool compose) internal view returns (ClaimExecutorV1.Config memory c) {
        c.venues = new ClaimExecutorV1.Venue[](compose ? 2 : 1);
        c.venues[0] = ClaimExecutorV1.Venue({target: address(dist), spender: address(0)});
        if (compose) c.venues[1] = ClaimExecutorV1.Venue({target: address(dex), spender: address(dex)});
        c.rewardTokens = new address[](1);
        c.rewardTokens[0] = address(reward);
        c.tokenOut = address(weth);
        c.oracle = address(oracle);
        c.maxSlippageBps = 50;
        c.dust = 0;
    }

    function _params(bytes32 action, ClaimExecutorV1.Config memory c)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(exec),
            evaluator: address(ev),
            asset: address(reward),
            maxTransactionValue: 0,
            maxCumulativeValue: 0,
            validFrom: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 0,
            funding: uint8(IShieldV1.FundingMode.NONE),
            action: action,
            actionConfig: abi.encode(uint8(1), c),
            trigger: "",
            outcome: ""
        });
    }

    function _claim(address to, bool claimStep) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call({
            target: address(dist),
            spender: address(0),
            approveToken: address(0),
            approveAmount: 0,
            claimStep: claimStep,
            data: abi.encodeCall(MockDistributor.claim, (principal, to))
        });
    }

    function _swap(uint256 amountIn, address to) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call({
            target: address(dex),
            spender: address(dex),
            approveToken: address(reward),
            approveAmount: amountIn,
            claimStep: false,
            data: abi.encodeCall(MockDex.swap, (address(reward), address(weth), amountIn, to))
        });
    }

    function _route1(IExecutorV1.Call memory a) internal pure returns (bytes memory) {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = a;
        return abi.encode(calls);
    }

    function _route2(IExecutorV1.Call memory a, IExecutorV1.Call memory b)
        internal
        pure
        returns (bytes memory)
    {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](2);
        calls[0] = a;
        calls[1] = b;
        return abi.encode(calls);
    }

    // ------------------------------------------------------------------ collect

    function test_collectPaysOwnerNothingPulled() public {
        IShieldV1.MandateParams memory p = _params(COLLECT, _cfg(false));
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        bytes memory r = _route1(_claim(principal, true));
        vm.prank(agent);
        uint256 spent = shield.fire(id, 0, r);
        assertEq(spent, 0);
        assertEq(reward.balanceOf(principal), 100e18);
        // nothing left to claim: the mandatory check refuses an empty claim
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r);
    }

    function test_collectRefusesApprovalsAndNonClaimSteps() public {
        IShieldV1.MandateParams memory p = _params(COLLECT, _cfg(false));
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        IExecutorV1.Call memory k = _claim(principal, false); // not marked as a claim step
        bytes memory r = _route1(k);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r);
    }

    // ------------------------------------------------------------------ compose

    function test_composeClaimsIntoSandboxAndReinvestsAtFairValue() public {
        IShieldV1.MandateParams memory p = _params(COMPOSE, _cfg(true));
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        address clone = exec.nextClone(id);
        bytes memory r = _route2(_claim(clone, true), _swap(100e18, clone));
        vm.prank(agent);
        shield.fire(id, 0, r);
        assertEq(weth.balanceOf(principal), 100e18);
        assertEq(reward.balanceOf(clone), 0);
        assertEq(weth.balanceOf(clone), 0);
    }

    function test_composeDiversionInsideTheClaimIsCaught() public {
        // The reviewer's case: a distributor that pays 100 then pulls 99 back through an allowance.
        // Our claim step carries no approval, so the pull fails and the firing reverts.
        IShieldV1.MandateParams memory p = _params(COMPOSE, _cfg(true));
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        address clone = exec.nextClone(id);
        dist.setDrain(9900);
        bytes memory r = _route2(_claim(clone, true), _swap(1e18, clone));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r);
        // a claim step that tries to carry an approval is refused outright
        dist.setDrain(0);
        IExecutorV1.Call memory k = _claim(clone, true);
        k.spender = address(dist);
        k.approveToken = address(reward);
        k.approveAmount = 100e18;
        bytes memory r2 = _route2(k, _swap(100e18, clone));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r2);
    }

    function test_composeUnderReinvestmentFailsTheValueRule() public {
        IShieldV1.MandateParams memory p = _params(COMPOSE, _cfg(true));
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        address clone = exec.nextClone(id);
        // reinvest only 60 of the 100 claimed: the other 40 would be swept to the owner as reward,
        // but the position rule demands the claimed value in tokenOut
        bytes memory r = _route2(_claim(clone, true), _swap(60e18, clone));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r);
        // a swap that pays 1% short fails the 0.5% tolerance
        dex.setSkim(100);
        bytes memory r2 = _route2(_claim(clone, true), _swap(100e18, clone));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r2);
    }

    function test_composeApprovalOnlyForDeclaredRewardTokens() public {
        IShieldV1.MandateParams memory p = _params(COMPOSE, _cfg(true));
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        address clone = exec.nextClone(id);
        IExecutorV1.Call memory s = _swap(100e18, clone);
        s.approveToken = address(weth); // not a declared reward token
        bytes memory r = _route2(_claim(clone, true), s);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 0, r);
    }
}

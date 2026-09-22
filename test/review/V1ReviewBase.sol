// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {ClaimExecutorV1} from "contracts/v1/ClaimExecutorV1.sol";
import {DisposableCloneV1} from "contracts/v1/DisposableCloneV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockExecutor, MockToken, MockWallet1271} from "test/v1/mocks/MockExecutor.sol";
import {MockDex, MockOracle, MockDistributor, MockMarket} from "test/v1/mocks/MockVenues.sol";
import {MockFeed, MockNasty} from "test/v1/mocks/MockCatalog.sol";

abstract contract V1ReviewBase is Test {
    ShieldV1 internal core;
    ExpressionEvaluator internal evaluator;
    GenericExecutorV1 internal generic;
    ClaimExecutorV1 internal claims;
    MockExecutor internal mock;
    MockToken internal asset;
    MockToken internal output;
    MockToken internal reward;
    MockDex internal dex;
    MockOracle internal oracle;
    MockDistributor internal distributor;
    MockMarket internal market;
    address internal principal;
    address internal agent = address(0xA6E);
    address internal enforcer = address(0xE0);
    address internal recipient = address(0xB0B);
    uint256 internal constant OWNER_KEY = 0xA11CE;
    bytes32 internal balanceId;
    bytes32 internal debtId;
    bytes32 internal collateralId;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        principal = vm.addr(OWNER_KEY);
        core = new ShieldV1(address(this), 0);
        evaluator = new ExpressionEvaluator(core);
        generic = new GenericExecutorV1(address(core));
        claims = new ClaimExecutorV1(address(core));
        mock = new MockExecutor(address(core));
        asset = new MockToken();
        output = new MockToken();
        reward = new MockToken();
        dex = new MockDex();
        oracle = new MockOracle();
        distributor = new MockDistributor(reward);
        market = new MockMarket(IERC20(address(asset)));
        core.setEnforcer(enforcer, true);
        core.setExecutor(address(generic), true);
        core.setExecutor(address(claims), true);
        core.setExecutor(address(mock), true);
        core.setEvaluator(address(evaluator), true);
        balanceId = core.listDescriptor(_descriptor(IERC20.balanceOf.selector));
        debtId = core.listDescriptor(_descriptor(bytes4(keccak256("debtOf(address)"))));
        collateralId = core.listDescriptor(_descriptor(bytes4(keccak256("collateralOf(address)"))));
        oracle.set(address(asset), 1e8);
        oracle.set(address(output), 1e8);
        oracle.set(address(reward), 1e8);
        asset.mint(principal, 1_000_000e18);
        vm.prank(principal);
        asset.approve(address(core), type(uint256).max);
    }

    function _descriptor(bytes4 selector) internal pure returns (IDescriptors.Descriptor memory d) {
        d.kind = IDescriptors.DescriptorKind.Shape;
        d.selector = selector;
        d.argCount = 1;
        d.subjectArg = 0;
        d.subjectRule = IDescriptors.SubjectRule.PrincipalRequired;
        d.gasStipend = 100_000;
        d.copyBytes = 32;
    }

    function _params(address executor, bytes32 action)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p.agent = agent;
        p.executor = executor;
        p.evaluator = address(evaluator);
        p.asset = address(asset);
        p.maxTransactionValue = 1_000e18;
        p.maxCumulativeValue = 10_000e18;
        p.maxFeeBps = 1_000;
        p.validFrom = uint48(vm.getBlockTimestamp());
        p.validUntil = uint48(vm.getBlockTimestamp() + 30 days);
        p.action = action;
    }

    function _mockParams() internal view returns (IShieldV1.MandateParams memory) {
        return _params(address(mock), keccak256("mock.transform"));
    }

    function _register(IShieldV1.MandateParams memory p) internal returns (bytes32) {
        vm.prank(principal);
        return core.registerMandate(p);
    }

    function _fire(bytes32 id, uint256 amount, bytes memory route) internal returns (uint256) {
        vm.prank(agent);
        return core.fire(id, amount, route);
    }

    function _trueTree() internal pure returns (bytes memory) {
        ExprLib.Read[] memory reads = new ExprLib.Read[](0);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](3);
        nodes[0] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 1, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 1, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.EQ), 0, 1);
        return abi.encode(reads, nodes);
    }

    function _tree(address target, bytes32 descriptor, ExprLib.Kind kind, uint8 decimals)
        internal
        view
        returns (bytes memory)
    {
        ExprLib.Read[] memory reads = new ExprLib.Read[](1);
        reads[0] =
            ExprLib.Read(descriptor, target, abi.encode(principal), ExprLib.Subject.Principal, decimals);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](3);
        nodes[0] = ExprLib.Node(uint8(kind), 0, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 0, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.GE), 0, 1);
        return abi.encode(reads, nodes);
    }

    function _genericConfig() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(dex), address(dex));
        c.sweepSet = new address[](0);
        c.tokenOut = address(output);
        c.oracle = address(oracle);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Oracle);
        c.maxSlippageBps = 50;
    }

    function _genericParams(bytes32 action, GenericExecutorV1.Config memory c)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p = _params(address(generic), action);
        p.actionConfig = abi.encode(uint8(1), c);
        p.outcome = _trueTree();
    }

    function _swap(address token, uint256 amount, address to)
        internal
        view
        returns (IExecutorV1.Call memory)
    {
        return IExecutorV1.Call(
            address(dex),
            address(dex),
            token,
            amount,
            false,
            abi.encodeCall(MockDex.swap, (token, address(output), amount, to))
        );
    }

    function _route(IExecutorV1.Call memory call_) internal pure returns (bytes memory) {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = call_;
        return abi.encode(calls);
    }

    function _claimConfig(bool compose) internal view returns (ClaimExecutorV1.Config memory c) {
        c.venues = new ClaimExecutorV1.Venue[](compose ? 2 : 1);
        c.venues[0] = ClaimExecutorV1.Venue(address(distributor), address(0));
        if (compose) c.venues[1] = ClaimExecutorV1.Venue(address(dex), address(dex));
        c.rewardTokens = new address[](1);
        c.rewardTokens[0] = address(reward);
        c.tokenOut = address(output);
        c.oracle = address(oracle);
        c.maxSlippageBps = 50;
    }

    function _claimParams(bool compose, ClaimExecutorV1.Config memory c)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p = _params(address(claims), compose ? claims.ACTION_CLAIM_COMPOSE() : claims.ACTION_CLAIM_COLLECT());
        p.asset = address(reward);
        p.funding = 1;
        p.maxTransactionValue = 0;
        p.maxCumulativeValue = 0;
        p.actionConfig = abi.encode(uint8(1), c);
        p.outcome = _trueTree();
    }

    function _claim(address who, address to, bool claimStep) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call(
            address(distributor),
            address(0),
            address(0),
            0,
            claimStep,
            abi.encodeCall(MockDistributor.claim, (who, to))
        );
    }

    function _repayConfig() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(market), address(market));
        c.sweepSet = new address[](0);
        c.tokenOut = address(asset);
        c.market = address(market);
        c.collateralTarget = address(market);
        c.debtDescriptor = debtId;
        c.collateralDescriptor = collateralId;
        c.maxSlippageBps = 50;
    }

    function _repayCall(uint256 amount) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call(
            address(market),
            address(market),
            address(asset),
            amount,
            false,
            abi.encodeCall(MockMarket.repay, (principal, amount))
        );
    }
}

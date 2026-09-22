// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Shield v1 generic executor against the real Aave pool on a fork of X Layer:
/// a supply as a fixed-rate transform through the sandbox (venue = the pool),
/// and a repay judged by the executor's debt and collateral reads through the
/// descriptor catalog. Block 70,752,723; RPC `XLAYER_RPC_URL` or the public one.
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";

contract GenericExecutorV1ForkTest is Test {
    uint256 internal constant FORK_BLOCK = 70_752_723;
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant A_USDT0 = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    address internal constant V_USDT0 = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");
    bytes32 internal constant REPAY = keccak256("generic.repay");

    ShieldV1 internal shield;
    ExpressionEvaluator internal ev;
    GenericExecutorV1 internal exec;
    IPool internal pool = IPool(POOL);
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    bytes32 internal dBalance;

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        shield = new ShieldV1(address(this), 0);
        ev = new ExpressionEvaluator(shield);
        exec = new GenericExecutorV1(address(shield));
        shield.setExecutor(address(exec), true);
        shield.setEvaluator(address(ev), true);
        dBalance = shield.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.Shape,
                target: address(0),
                selector: IERC20.balanceOf.selector,
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
        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(principal, 100e6);
        vm.startPrank(principal);
        IERC20(XETH).approve(POOL, type(uint256).max);
        pool.supply(XETH, 0.05e18, principal, 0);
        pool.borrow(USDT0, 60e6, 2, 0, principal);
        IERC20(USDT0).approve(address(shield), type(uint256).max);
        IERC20(XETH).approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    function _params(bytes32 action, address asset, uint256 cap, GenericExecutorV1.Config memory c)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p.agent = agent;
        p.executor = address(exec);
        p.evaluator = address(ev);
        p.action = action;
        p.asset = asset;
        p.maxTransactionValue = cap;
        p.maxCumulativeValue = cap * 2;
        p.validFrom = 0;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.actionConfig = abi.encode(uint8(1), c);
    }

    function _route(IExecutorV1.Call memory k) internal pure returns (bytes memory) {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = k;
        return abi.encode(calls);
    }

    /// Supply xETH to Aave as a generic transform: venue (pool, pool), output aXETH one-to-one.
    function test_supplyThroughTheSandboxAsAFixedRateTransform() public {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: POOL, spender: POOL});
        c.sweepSet = new address[](0);
        c.tokenOut = A_XETH;
        c.rateKind = uint8(GenericExecutorV1.RateKind.Fixed);
        c.rateOrFloor = 1e18; // one aToken per token
        c.maxSlippageBps = 10;
        IShieldV1.MandateParams memory p = _params(TRANSFORM, XETH, 0.01e18, c);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        address clone = exec.nextClone(id);
        IExecutorV1.Call memory k = IExecutorV1.Call({
            target: POOL,
            spender: POOL,
            approveToken: XETH,
            approveAmount: 0.01e18,
            claimStep: false,
            data: abi.encodeCall(IPool.supply, (XETH, 0.01e18, principal, 0))
        });
        bytes memory route = _route(k);
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 0.01e18, route);
        assertEq(spent, 0.01e18);
        assertApproxEqAbs(
            IERC20(A_XETH).balanceOf(principal) - aBefore, 0.01e18, 2, "aXETH rose by the amount"
        );
        assertEq(IERC20(XETH).balanceOf(clone), 0);
        assertEq(IERC20(XETH).allowance(clone, POOL), 0, "no approval survives");
    }

    /// Repay USD-T0 debt on the real pool through the generic executor, judged by the debt and collateral reads.
    function test_repayOnTheRealPoolJudgedByCatalogReads() public {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: POOL, spender: POOL});
        c.sweepSet = new address[](0);
        c.tokenOut = USDT0;
        c.market = V_USDT0; // the debt read targets the variable debt token (debt-asset units)
        c.collateralTarget = A_XETH; // the collateral read targets the collateral aToken
        c.maxSlippageBps = 10;
        c.debtDescriptor = dBalance;
        c.collateralDescriptor = dBalance;
        IShieldV1.MandateParams memory p = _params(REPAY, USDT0, 20e6, c);
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);
        IExecutorV1.Call memory k = IExecutorV1.Call({
            target: POOL,
            spender: POOL,
            approveToken: USDT0,
            approveAmount: 10e6,
            claimStep: false,
            data: abi.encodeCall(IPool.repay, (USDT0, 10e6, 2, principal))
        });
        bytes memory route = _route(k);
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, 10e6, route);
        assertEq(spent, 10e6);
        assertApproxEqAbs(
            debtBefore - IERC20(V_USDT0).balanceOf(principal), 10e6, 2, "debt fell by the repayment"
        );
        // paying someone else's debt spends without reducing the owner's: refused
        IExecutorV1.Call memory bad = k;
        bad.data = abi.encodeCall(IPool.repay, (USDT0, 10e6, 2, A_USDT0));
        bytes memory badRoute = _route(bad);
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 10e6, badRoute);
    }
}

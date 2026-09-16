// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";

/// Tier 1 on the real X Layer Aave pool (FLIP-238): an Aave supply through
/// the generic executor with NO protocol Solidity in the path (the clone
/// calls `pool.supply` with calldata the agent built), measured against the
/// Tier 2 adapter's own supply on the same amount so the cost of generality
/// is a number.
contract GenericExecutorForkTest is Test {
    /// The block the OKX fixture below was quoted at (tools/okx-fixture.py
    /// --adapter <predicted clone> --amount-in 50000000000000000); the supply
    /// test does not care which block it runs at.
    uint256 internal constant FORK_BLOCK = 70_793_363;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant OKX_ROUTER = 0x7c5bEE2a8091C3ef39072f64F18Fac913060AEaF;
    address internal constant OKX_SPENDER = 0x8b773D83bc66Be128c60e07E17C8901f7a64F000;
    /// The sandbox the fixture was quoted for: the executor's first clone for the
    /// swap mandate. If it drifts, regenerate the fixture rather than editing it.
    address internal constant FIXTURE_CLONE = 0x5980c7d9a937CF807ccB3A8639b6Aa4f54a16fD8;
    uint256 internal constant AMOUNT_IN = 0.05e18;
    uint256 internal constant QUOTED_OUT = 120273456;
    bytes internal constant OKX_CALLDATA =
        hex"f2c42696000000000000000000000000000000000000000000000000000000003bc28e8c000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373600000000000000000000000000000000000000000000000000b1a2bc2ec50000000000000000000000000000000000000000000000000000000000000718e001000000000000000000000000000000000000000000000000000000006aaa9c3000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000160000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000000000000000000000000000000000000000000100000000000000000000000069a52a0570636ca391175ce619bbb9d348040bbc000000000000000000000000000000000000000000000000000000000000000100000000000000000000000069a52a0570636ca391175ce619bbb9d348040bbc000000000000000000000000000000000000000000000000000000000000000180000000000000000001271069a52a0570636ca391175ce619bbb9d348040bbc0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be713736000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000fff3b84ea7fc31000000000000000000000000000000000000000000000000000000000000000360000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000120000000000000000000000000e415dd1c60719400726f9712b904fff522cf9cc6000000000000000000000000e415dd1c60719400726f9712b904fff522cf9cc6000000000000000000012710000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000040000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be713736000000000000000000000000311350ded40088b8504bb67a7d5974e9da287bd1000000000000000000000000311350ded40088b8504bb67a7d5974e9da287bd1000000000000000000012710154586b2479b9a11e3d4db90024dc0e26f09731200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000060335c400406e84be9c8026ae2b9f8ab07fad4d26bcb8a4c8aede0c9b463618258000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373600000000000000000000000000000000000000000000000000000000000000010000000000000000000000007c5bee2a8091c3ef39072f64f18fac913060aeaf00000000000000000000000000000000000000000000000000000000000000405fdefd5819125e3b8d317fcdfa99886aa87cdbffdacb6f45230272c01d0624ea3b472602d259a3dd3659416bc5e6da1ba19002b248f1fb6215b5ff863b22a96377777777111180000000000000000000000000000000000000000000072b3a30777777771111000000000064fa00a9ed787f3793db668bff3e6e6e7db0f92a1b";
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;

    SignoShield internal shield;
    AaveV3Adapter internal adapter;
    GenericExecutor internal executor;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal feeSink = makeAddr("feeSink");
    uint48 internal validUntil;

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        validUntil = uint48(block.timestamp + 30 days);
        ConditionModule conditions = new ConditionModule();
        shield = new SignoShield(address(this), conditions, 10);
        adapter = new AaveV3Adapter(address(shield), IPool(POOL));
        executor = new GenericExecutor(address(shield));
        shield.setAdapter(address(adapter), true);
        shield.setAdapter(address(executor), true);
        shield.setFeeRecipient(feeSink);
        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.prank(principal);
        IERC20(XETH).approve(address(shield), type(uint256).max);
    }

    function _noCondition() internal pure returns (ICondition.Condition memory c) {
        c.comparator = ICondition.Comparator.LessThan;
    }

    function _base(address adapterAddr, bytes32 action)
        internal
        view
        returns (ISignoShield.MandateParams memory p)
    {
        p.agent = agent;
        p.adapter = adapterAddr;
        p.action = action;
        p.asset = XETH;
        p.maxTransactionValue = 0.1e18;
        p.maxCumulativeValue = 0.2e18;
        p.validUntil = validUntil;
        p.condition = _noCondition();
    }

    function test_supply_throughTheExecutor_matchesTheAdapterAndCostsThis() public {
        // Tier 1: the mandate pins the pool as the surface and the aToken as the
        // 1:1 receipt; the agent's calldata is a plain pool.supply for the owner.
        ISignoShield.MandateParams memory p = _base(address(executor), executor.ACTION_TRANSFORM());
        p.actionConfig = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: A_XETH,
                target: POOL,
                spender: POOL,
                rateKind: GenericExecutor.RateKind.Fixed,
                oracle: address(0),
                rateOrFloor: 1e18,
                maxSlippageBps: 0
            })
        );
        vm.prank(principal);
        bytes32 generic = shield.registerMandate(p);
        address clone = executor.nextClone(generic);
        bytes memory data = abi.encodeCall(IPool.supply, (XETH, 0.05e18, principal, 0));
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        uint256 xBefore = IERC20(XETH).balanceOf(principal);
        vm.prank(agent);
        uint256 gasBefore = gasleft();
        uint256 spent = shield.fire(generic, 0.05e18, data);
        uint256 gasGeneric = gasBefore - gasleft();
        assertEq(spent, 0.05e18 + 0.00005e18, "amount plus the 10 bps fee");
        assertApproxEqAbs(
            IERC20(A_XETH).balanceOf(principal) - aBefore, 0.05e18, 2, "the aTokens landed with the owner"
        );
        assertEq(xBefore - IERC20(XETH).balanceOf(principal), 0.05e18 + 0.00005e18);
        assertEq(IERC20(XETH).balanceOf(clone), 0, "sandbox holds nothing");
        assertEq(IERC20(A_XETH).balanceOf(clone), 0);
        assertEq(IERC20(XETH).allowance(clone, POOL), 0, "no approval survives");
        assertEq(IERC20(XETH).balanceOf(address(executor)), 0);

        // Tier 2, same amount, same pool, the adapter's own supply.
        ISignoShield.MandateParams memory q = _base(address(adapter), adapter.ACTION_SUPPLY());
        vm.prank(principal);
        bytes32 tier2 = shield.registerMandate(q);
        aBefore = IERC20(A_XETH).balanceOf(principal);
        vm.prank(agent);
        gasBefore = gasleft();
        shield.fire(tier2, 0.05e18, "");
        uint256 gasAdapter = gasBefore - gasleft();
        assertApproxEqAbs(IERC20(A_XETH).balanceOf(principal) - aBefore, 0.05e18, 2);

        console.log("gas, supply through the generic executor:", gasGeneric);
        console.log("gas, supply through the Aave adapter:    ", gasAdapter);
        console.log(
            "delta (generality cost):                  ",
            gasGeneric > gasAdapter ? gasGeneric - gasAdapter : 0
        );
    }

    /// xETH -> USD-T0 through the real OKX aggregator, bounded by the Aave
    /// oracle at 1 %: the surface is pinned, the rate rule is pinned, the
    /// agent supplied the amount and the calldata only.
    function _registerSwap() internal returns (bytes32 id) {
        ISignoShield.MandateParams memory p = _base(address(executor), executor.ACTION_TRANSFORM());
        p.actionConfig = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: USDT0,
                target: OKX_ROUTER,
                spender: OKX_SPENDER,
                rateKind: GenericExecutor.RateKind.Oracle,
                oracle: ORACLE,
                rateOrFloor: 0,
                maxSlippageBps: 100
            })
        );
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    /// The sandbox address is knowable before quoting; the fixture names it as
    /// the wallet the swap runs for. If this fails, regenerate the fixture.
    function test_fixtureMatchesThePredictedClone() public {
        bytes32 id = _registerSwap();
        assertEq(executor.nextClone(id), FIXTURE_CLONE, "clone address drifted; regenerate the OKX fixture");
    }

    function test_swap_throughTheExecutor_realOkxCalldata() public {
        bytes32 id = _registerSwap();
        address clone = executor.nextClone(id);
        uint256 usdtBefore = IERC20(USDT0).balanceOf(principal);
        uint256 xBefore = IERC20(XETH).balanceOf(principal);
        vm.prank(agent);
        uint256 gasBefore = gasleft();
        uint256 spent = shield.fire(id, AMOUNT_IN, OKX_CALLDATA);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 received = IERC20(USDT0).balanceOf(principal) - usdtBefore;
        assertEq(spent, AMOUNT_IN + AMOUNT_IN / 1000, "the whole slice sold, plus the fee");
        assertEq(xBefore - IERC20(XETH).balanceOf(principal), AMOUNT_IN + AMOUNT_IN / 1000);
        assertApproxEqRel(received, QUOTED_OUT, 0.01e18, "within 1 % of the quote");
        assertEq(IERC20(XETH).balanceOf(clone), 0, "sandbox holds nothing");
        assertEq(IERC20(USDT0).balanceOf(clone), 0);
        assertEq(IERC20(XETH).allowance(clone, OKX_SPENDER), 0, "no approval survives");
        assertEq(IERC20(XETH).balanceOf(address(executor)), 0);
        assertEq(IERC20(USDT0).balanceOf(address(executor)), 0);
        console.log("received USD-T0 (6 dec):", received);
        console.log("gas, OKX swap through the generic executor:", gasUsed);
    }
}

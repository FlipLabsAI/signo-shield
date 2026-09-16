// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ConditionModule} from "contracts/core/ConditionModule.sol";
import {SignoShield} from "contracts/core/SignoShield.sol";
import {ICondition} from "contracts/core/interfaces/ICondition.sol";
import {ISignoShield} from "contracts/core/interfaces/ISignoShield.sol";

/// Repay-with-collateral through the REAL OKX DEX aggregator router on X Layer
/// (FLIP-228). The swap calldata below was produced by the OKX Onchain OS API
/// for this exact adapter address at the pinned block, the way Signo's agent
/// will produce it at firing time, and is replayed here against a fork of the
/// same state. No key is needed to run it; `tools/okx-fixture.py` regenerates it.
contract AaveV3AdapterOkxForkTest is Test {
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant V_USDT0 = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;

    /// OKX DEX aggregator on X Layer, read from the API on 2026-09-16: the
    /// router the swap transaction is sent to, and the approval contract that
    /// pulls the input token (`dexTokenApproveAddress`).
    address internal constant OKX_ROUTER = 0x7c5bEE2a8091C3ef39072f64F18Fac913060AEaF;
    address internal constant OKX_SPENDER = 0x8b773D83bc66Be128c60e07E17C8901f7a64F000;

    // From tools/okx-fixture.py: the block the calldata was quoted at, the
    // adapter address it was quoted for, and the calldata itself.
    uint256 internal constant FORK_BLOCK = 70756518;
    address internal constant FIXTURE_ADAPTER = 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a;
    uint256 internal constant SLICE = 0.008e18; // aTokens the Shield pulls
    uint256 internal constant AMOUNT_IN = 0.0079e18; // xETH the OKX calldata sells
    bytes internal constant OKX_CALLDATA =
        hex"f2c42696000000000000000000000000000000000000000000000000000000003bc28e8c000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be713736000000000000000000000000000000000000000000000000001c110215b9c00000000000000000000000000000000000000000000000000000000000011e25d1000000000000000000000000000000000000000000000000000000006aaa0c4200000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000160000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000cc96b656b6dff0b5318d53271b82b7e7183b95d20000000000000000000000000000000000000000000000000000000000000001000000000000000000000000cc96b656b6dff0b5318d53271b82b7e7183b95d200000000000000000000000000000000000000000000000000000000000000018000000000000000000127106e18cebfb9c5bbcf127b97a6dab026e941fff6d50000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000040000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a0000000000000000000000004ae46a509f6b1d9056937ba4500cb143933d2dc800000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001600000000000000000000000004ae46a509f6b1d9056937ba4500cb143933d2dc80000000000000000000000000000000000000000000000000000000000000001000000000000000000000000bb8ca112ec75db02f9efec50593f99b7c4a74f3e0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000bb8ca112ec75db02f9efec50593f99b7c4a74f3e000000000000000000000000000000000000000000000000000000000000000100000000000000000102271000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000004ae46a509f6b1d9056937ba4500cb143933d2dc8000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373600000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000077777777111180000000000000000000000000000000000000000000012109c2777777771111000000000064fa00a9ed787f3793db668bff3e6e6e7db0f92a1b";

    SignoShield internal shield;
    ConditionModule internal conditions;
    AaveV3Adapter internal adapter;
    IPool internal pool = IPool(POOL);

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        conditions = new ConditionModule();
        shield = new SignoShield(address(this), conditions, 10);
        adapter = new AaveV3Adapter(address(shield), pool);
        shield.setAdapter(address(adapter), true);

        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.startPrank(principal);
        IERC20(XETH).approve(POOL, type(uint256).max);
        pool.supply(XETH, 0.05e18, principal, 0);
        pool.borrow(USDT0, 60e6, 2, 0, principal);
        IERC20(A_XETH).approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    function _healthFactor(address user) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(user);
    }

    /// The calldata names the adapter as the wallet the swap runs for, so the
    /// deployment order above must keep producing the same address. If this
    /// fails, regenerate the fixture rather than editing the address.
    function test_fixtureMatchesTheDeployedAdapter() public view {
        console.log("adapter", address(adapter));
        assertEq(address(adapter), FIXTURE_ADAPTER, "adapter address drifted; regenerate the OKX fixture");
    }

    function test_repayWithCollateral_throughTheRealOkxRouter() public {
        ISignoShield.MandateParams memory p;
        p.agent = agent;
        p.adapter = address(adapter);
        p.action = adapter.ACTION_REPAY_WITH_COLLATERAL();
        p.asset = A_XETH;
        p.maxTransactionValue = 0.01e18;
        p.maxCumulativeValue = 0.02e18;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.condition = ICondition.Condition({
            target: POOL,
            callData: abi.encodeCall(IPool.getUserAccountData, (principal)),
            wordOffset: 5,
            comparator: ICondition.Comparator.LessThan,
            threshold: 1.6e18
        });
        p.actionConfig = abi.encode(
            AaveV3Adapter.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: 1.7e18,
                maxSlippageBps: 100,
                router: OKX_ROUTER,
                spender: OKX_SPENDER
            })
        );
        vm.prank(principal);
        bytes32 id = shield.registerMandate(p);

        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 aBefore = IERC20(A_XETH).balanceOf(principal);
        uint256 xethBefore = IERC20(XETH).balanceOf(principal);
        assertLt(_healthFactor(principal), 1.6e18, "fixture: trigger is true");

        vm.prank(agent);
        uint256 spent = shield.fire(id, SLICE, OKX_CALLDATA);

        uint256 repaid = debtBefore - IERC20(V_USDT0).balanceOf(principal);
        console.log("repaid USDT0 (6 dec)", repaid);
        console.log("health factor after", _healthFactor(principal));
        assertApproxEqAbs(spent, SLICE, 2, "the whole slice was spent");
        assertApproxEqAbs(
            aBefore - IERC20(A_XETH).balanceOf(principal), SLICE, 2, "collateral slice left the position"
        );
        assertGt(repaid, 18e6, "about 19 USD-T0 of debt repaid from 0.0079 xETH");
        assertGe(_healthFactor(principal), 1.7e18, "health factor at or above target");
        assertEq(
            IERC20(XETH).balanceOf(principal) - xethBefore, SLICE - AMOUNT_IN, "unsold dust came home as xETH"
        );
        assertEq(IERC20(XETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDT0).balanceOf(address(adapter)), 0);
        assertEq(IERC20(A_XETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(XETH).allowance(address(adapter), OKX_SPENDER), 0, "no approval survives");
        assertEq(shield.getMandate(id).cumulativeUsed, spent);
    }
}

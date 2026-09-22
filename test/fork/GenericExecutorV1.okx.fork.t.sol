// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// A swap through the REAL OKX DEX aggregator router on X Layer from the v1
/// sandbox. The calldata is produced by tools/okx-fixture.py, quoted for the
/// sandbox address the test's deploy order yields (printed by
/// `test_printSandboxAddress`), at the block pinned below.
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";

contract GenericExecutorV1OkxForkTest is Test {
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant OKX_ROUTER = 0x7c5bEE2a8091C3ef39072f64F18Fac913060AEaF;
    address internal constant OKX_SPENDER = 0x8b773D83bc66Be128c60e07E17C8901f7a64F000;
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");

    // From tools/okx-fixture.py, quoted for FIXTURE_SANDBOX at FORK_BLOCK.
    uint256 internal constant FORK_BLOCK = 71326815;
    address internal constant FIXTURE_SANDBOX = 0x03f62b157AdF845786240Fb7E587B2d4072edf5a;
    uint256 internal constant AMOUNT_IN = 0.0079e18;
    bytes internal constant OKX_CALLDATA =
        hex"f2c42696000000000000000000000000000000000000000000000000000000003bc28e8c000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be713736000000000000000000000000000000000000000000000000001c110215b9c000000000000000000000000000000000000000000000000000000000000147c369000000000000000000000000000000000000000000000000000000006ab2bffc00000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000160000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e415dd1c60719400726f9712b904fff522cf9cc60000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e415dd1c60719400726f9712b904fff522cf9cc600000000000000000000000000000000000000000000000000000000000000010000000000000000000127100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000040000000000000000000000000e7b000003a45145decf8a28fc755ad5ec5ea025a000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373677777777111180000000000000000000000000000000000000000000014b12f67777777711110000000000647fc8fd8bb3192e2d62a3d8d97d9a7924d4bae58b";

    ShieldV1 internal shield;
    ExpressionEvaluator internal ev;
    GenericExecutorV1 internal exec;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        shield = new ShieldV1(address(this), 0);
        ev = new ExpressionEvaluator(shield);
        exec = new GenericExecutorV1(address(shield));
        shield.setExecutor(address(exec), true);
        shield.setEvaluator(address(ev), true);
        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.prank(principal);
        IERC20(XETH).approve(address(shield), type(uint256).max);
    }

    function _register() internal returns (bytes32 id) {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: OKX_ROUTER, spender: OKX_SPENDER});
        c.sweepSet = new address[](0);
        c.tokenOut = USDT0;
        c.rateKind = uint8(GenericExecutorV1.RateKind.Oracle);
        c.oracle = ORACLE;
        c.maxSlippageBps = 100;
        IShieldV1.MandateParams memory p;
        p.agent = agent;
        p.executor = address(exec);
        p.evaluator = address(ev);
        p.action = TRANSFORM;
        p.asset = XETH;
        p.maxTransactionValue = 0.01e18;
        p.maxCumulativeValue = 0.02e18;
        p.validFrom = 0;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    /// Run first to learn the sandbox address the fixture must be quoted for.
    function test_printSandboxAddress() public {
        bytes32 id = _register();
        console2.log("sandbox for the OKX fixture:", exec.nextClone(id));
        console2.log("mandate:", vm.toString(id));
    }

    function test_swapThroughTheRealOkxRouterFromTheSandbox() public {
        if (OKX_CALLDATA.length == 0) return; // fixture not yet generated
        bytes32 id = _register();
        address clone = exec.nextClone(id);
        assertEq(clone, FIXTURE_SANDBOX, "sandbox address drifted; regenerate the OKX fixture");
        IExecutorV1.Call memory k = IExecutorV1.Call({
            target: OKX_ROUTER,
            spender: OKX_SPENDER,
            approveToken: XETH,
            approveAmount: AMOUNT_IN,
            claimStep: false,
            data: OKX_CALLDATA
        });
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = k;
        bytes memory route = abi.encode(calls);
        uint256 uBefore = IERC20(USDT0).balanceOf(principal);
        uint256 xBefore = IERC20(XETH).balanceOf(principal);
        vm.prank(agent);
        uint256 spent = shield.fire(id, AMOUNT_IN, route);
        assertEq(spent, AMOUNT_IN, "the whole slice was sold");
        assertEq(xBefore - IERC20(XETH).balanceOf(principal), AMOUNT_IN);
        assertGt(IERC20(USDT0).balanceOf(principal) - uBefore, 0, "USD-T0 arrived on the owner");
        assertEq(IERC20(XETH).balanceOf(clone), 0);
        assertEq(IERC20(USDT0).balanceOf(clone), 0);
        assertEq(IERC20(XETH).allowance(clone, OKX_SPENDER), 0, "no approval survives");
    }
}

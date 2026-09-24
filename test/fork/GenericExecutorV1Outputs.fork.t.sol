// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Round 12 on a fork of X Layer (Austin, 24 Sep: "test it for all sorts of
/// complex operations ... tokens with less liquidity or unpriced vaults").
/// Real tokens (USD-T0 6 decimals, xBTC 8, xETH 18, USDG), the real Aave
/// oracle, and the real Chainlink rounds bound as DeployV1 binds them; a mock
/// router pays whatever each case needs, so a route can be fair, thin, split
/// or empty on purpose. RPC: `XLAYER_RPC_URL`, defaulting to the public endpoint.
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {IAaveOracle} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {MockRouter} from "../mocks/MockRouter.sol";

contract GenericExecutorV1OutputsForkTest is Test {
    uint256 internal constant FORK_BLOCK = 71338142; // rounds 0-4 h old here
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant XBTC = 0xb7C00000bcDEeF966b20B3D884B98E64d2b06b4f;
    address internal constant USDG = 0x4ae46a509F6b1D9056937BA4500cb143933D2dc8;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant VAULT = 0x97e7620A3229b3daC7049C537B0E29DA2D1021E1; // waXlrUSDG (ERC-4626)
    address internal constant FEED_ETH = 0x8b85b50535551F8E8cDAF78dA235b5Cf1005907b;
    address internal constant FEED_BTC = 0x4D6f6488a2B3a5f7b088f276887f608a1e9805c4;
    address internal constant FEED_USDT = 0xb928a0678352005a2e51F614efD0b54C9830dB80;
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");

    ShieldRegistryV1 internal registry;
    ShieldV1 internal shield;
    ExpressionEvaluator internal ev;
    GenericExecutorV1 internal exec;
    MockRouter internal router;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        registry = new ShieldRegistryV1(address(this));
        shield = new ShieldV1(registry, 0);
        ev = new ExpressionEvaluator(registry);
        exec = new GenericExecutorV1(address(shield));
        registry.setExecutor(address(exec), true);
        registry.setEvaluator(address(ev), true);
        // The fresh-round rules DeployV1 binds (25 h), for the three priced here.
        _bind(XETH, FEED_ETH);
        _bind(XBTC, FEED_BTC);
        _bind(USDT0, FEED_USDT);
        router = new MockRouter();
        deal(XETH, address(router), 100e18);
        deal(XBTC, address(router), 10e8);
        deal(USDG, address(router), 1_000_000e6);
        deal(USDT0, principal, 10_000e6);
        vm.prank(principal);
        IERC20(USDT0).approve(address(shield), type(uint256).max);
    }

    function _bind(address token, address feed) internal {
        bytes32 id = registry.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.PerAddress,
                target: feed,
                selector: bytes4(keccak256("latestRoundData()")),
                argCount: 0,
                subjectArg: -1,
                subjectRule: IDescriptors.SubjectRule.None,
                word: 1,
                isSigned: true,
                mustBePositive: true,
                decimals: 8,
                freshness: IDescriptors.Freshness.ChainlinkRound,
                maxAge: 25 hours,
                gasStipend: 160_000,
                copyBytes: 160,
                unboundedTop: false
            })
        );
        registry.setPriceRound(token, id, feed);
    }

    /// A mandate selling USD-T0 for `outs[0]` or any of the rest, at the oracle.
    function _params(address[] memory outs, uint16 slippageBps)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(router), spender: address(router)});
        c.sweepSet = new address[](0);
        c.tokenOut = outs[0];
        c.rateKind = uint8(GenericExecutorV1.RateKind.Oracle);
        c.oracle = ORACLE;
        c.maxSlippageBps = slippageBps;
        c.moreOuts = new GenericExecutorV1.Output[](outs.length - 1);
        address[] memory priced = new address[](outs.length + 1);
        priced[0] = USDT0;
        priced[1] = outs[0];
        for (uint256 i = 1; i < outs.length; i++) {
            c.moreOuts[i - 1] = GenericExecutorV1.Output({token: outs[i], floor: 0});
            priced[i + 1] = outs[i];
        }
        c.prices = PinnedPrices.pin(IShieldRegistryV1(address(registry)), priced);
        p.agent = agent;
        p.executor = address(exec);
        p.evaluator = address(ev);
        p.action = TRANSFORM;
        p.asset = USDT0;
        p.maxTransactionValue = 1_000e6;
        p.maxCumulativeValue = 10_000e6;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.actionConfig = abi.encode(uint8(1), c);
    }

    function _register(address[] memory outs, uint16 slippageBps) internal returns (bytes32 id) {
        IShieldV1.MandateParams memory p = _params(outs, slippageBps);
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _outs(address a, address b) internal pure returns (address[] memory o) {
        o = new address[](2);
        o[0] = a;
        o[1] = b;
    }

    /// What `usdt` (6 decimals) buys of `token` at Aave's oracle, times `bps`/10,000.
    function _fair(address token, uint256 usdt, uint256 bps) internal view returns (uint256) {
        IAaveOracle o = IAaveOracle(ORACLE);
        uint8 dec = token == XBTC ? 8 : token == USDG ? 6 : 18;
        return usdt * o.getAssetPrice(USDT0) * (10 ** dec) / (o.getAssetPrice(token) * 1e6) * bps / 10_000;
    }

    function _pay(address tokenOut, uint256 usdt, uint256 out, address clone)
        internal
        view
        returns (IExecutorV1.Call memory)
    {
        return IExecutorV1.Call({
            target: address(router),
            spender: address(router),
            approveToken: USDT0,
            approveAmount: usdt,
            claimStep: false,
            data: abi.encodeCall(MockRouter.swap, (USDT0, usdt, tokenOut, out, clone))
        });
    }

    function _fire(bytes32 id, uint256 amount, IExecutorV1.Call[] memory calls) internal returns (uint256) {
        vm.prank(agent);
        return shield.fire(id, amount, abi.encode(calls));
    }

    /// The executor's own error inside the core's OutcomeRejected, for a firing
    /// that must be refused for a named reason (not merely refused).
    function _refusedWith(bytes32 id, uint256 amount, IExecutorV1.Call[] memory calls)
        internal
        returns (bytes4)
    {
        vm.prank(agent);
        try shield.fire(id, amount, abi.encode(calls)) returns (uint256) {
            return bytes4(0);
        } catch (bytes memory err) {
            if (bytes4(err) != IShieldV1.OutcomeRejected.selector) return bytes4(err);
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i = 0; i < body.length; i++) {
                body[i] = err[i + 4];
            }
            (,, bytes memory inner) = abi.decode(body, (bytes32, uint8, bytes));
            return bytes4(inner);
        }
    }

    function _one(IExecutorV1.Call memory a) internal pure returns (IExecutorV1.Call[] memory k) {
        k = new IExecutorV1.Call[](1);
        k[0] = a;
    }

    function _two(IExecutorV1.Call memory a, IExecutorV1.Call memory b)
        internal
        pure
        returns (IExecutorV1.Call[] memory k)
    {
        k = new IExecutorV1.Call[](2);
        k[0] = a;
        k[1] = b;
    }

    /// Low liquidity: the check compares what arrived with the oracle, never with
    /// the route's own quote. A thin route into either output reverts; a fair one
    /// within the slippage fires. Six, eight and eighteen decimals in one mandate.
    function test_r12f_aThinRouteIntoEitherOutputIsRefused() public {
        bytes32 id = _register(_outs(XETH, XBTC), 100);
        // A reverted firing uses no sandbox, so the next clone stays the same.
        address clone = exec.nextClone(id);
        IExecutorV1.Call[] memory thinBtc = _one(_pay(XBTC, 100e6, _fair(XBTC, 100e6, 9_800), clone)); // 2% short
        IExecutorV1.Call[] memory thinEth = _one(_pay(XETH, 100e6, _fair(XETH, 100e6, 9_800), clone));
        uint256 fair = _fair(XBTC, 100e6, 9_950); // 0.5% short, inside 1%
        IExecutorV1.Call[] memory fairBtc = _one(_pay(XBTC, 100e6, fair, clone));
        assertEq(_refusedWith(id, 100e6, thinBtc), GenericExecutorV1.OutputBelowMinimum.selector);
        assertEq(_refusedWith(id, 100e6, thinEth), GenericExecutorV1.OutputBelowMinimum.selector);
        _fire(id, 100e6, fairBtc);
        assertEq(IERC20(XBTC).balanceOf(principal), fair);
        assertEq(IERC20(XETH).balanceOf(principal), 0);
    }

    /// The bound is on the total value that arrived: one bad leg is allowed only
    /// while the whole firing stays inside the slippage.
    function test_r12f_theBoundIsOnTheTotalNotEachLeg() public {
        bytes32 id = _register(_outs(XETH, XBTC), 100);
        address clone = exec.nextClone(id);
        // 60 fair + 40 at 5% short = 2% short in total: refused.
        IExecutorV1.Call[] memory bad = _two(
            _pay(XETH, 60e6, _fair(XETH, 60e6, 10_000), clone),
            _pay(XBTC, 40e6, _fair(XBTC, 40e6, 9_500), clone)
        );
        // 90 fair + 10 at 5% short = 0.5% short in total: fires.
        IExecutorV1.Call[] memory ok = _two(
            _pay(XETH, 90e6, _fair(XETH, 90e6, 10_000), clone),
            _pay(XBTC, 10e6, _fair(XBTC, 10e6, 9_500), clone)
        );
        assertEq(_refusedWith(id, 100e6, bad), GenericExecutorV1.OutputBelowMinimum.selector);
        _fire(id, 100e6, ok);
        assertGt(IERC20(XETH).balanceOf(principal), 0);
        assertGt(IERC20(XBTC).balanceOf(principal), 0);
    }

    /// Unpriced vaults: a vault share (ERC-4626) or an aToken cannot be an
    /// output under the oracle rule. Aave's oracle does not price them (it
    /// reverts), so registration fails; they are never valued against their base.
    function test_r12f_vaultSharesAndATokensCannotBeOutputs() public {
        IShieldV1.MandateParams memory p = _params(_outs(XETH, VAULT), 100);
        vm.prank(principal);
        vm.expectRevert();
        shield.registerMandate(p);
        p = _params(_outs(XETH, A_XETH), 100);
        vm.prank(principal);
        vm.expectRevert();
        shield.registerMandate(p);
        // As the only output too.
        p = _params(_outs(VAULT, XETH), 100);
        vm.prank(principal);
        vm.expectRevert();
        shield.registerMandate(p);
    }

    /// USDG is an Aave reserve with no Chainlink round bound. Round 13 (G12-H2):
    /// it cannot be one of several outputs (only reviewed tokens with a bound
    /// round can), while a one-token oracle swap into USDG is still judged at
    /// Aave's own price, as before round 12.
    function test_r13_aTokenWithoutABoundRoundCannotBeOneOfSeveral() public {
        (bytes32 id0,) = registry.priceRound(USDG);
        assertEq(id0, bytes32(0), "USDG has no bound round");
        IShieldV1.MandateParams memory p = _params(_outs(XETH, USDG), 100);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "moreOuts"));
        shield.registerMandate(p);
        // One output: admitted, judged at Aave's price (positivity only).
        address[] memory one = new address[](1);
        one[0] = USDG;
        bytes32 id = _register(one, 100);
        address clone = exec.nextClone(id);
        IExecutorV1.Call[] memory thin = _one(_pay(USDG, 100e6, _fair(USDG, 100e6, 9_800), clone));
        IExecutorV1.Call[] memory fair = _one(_pay(USDG, 100e6, _fair(USDG, 100e6, 9_950), clone));
        assertEq(_refusedWith(id, 100e6, thin), GenericExecutorV1.OutputBelowMinimum.selector);
        _fire(id, 100e6, fair);
        assertGt(IERC20(USDG).balanceOf(principal), 0);
    }

    /// A stale round stops the firing whatever the route pays: every signed
    /// output's round is checked, not only the one the route delivered.
    function test_r12f_aStaleRoundOnAnyOutputStopsTheFiring() public {
        bytes32 id = _register(_outs(XETH, XBTC), 100);
        // Control: the same fair route fires while the rounds are fresh.
        address clone = exec.nextClone(id);
        _fire(id, 100e6, _one(_pay(XETH, 100e6, _fair(XETH, 100e6, 10_000), clone)));
        vm.warp(vm.getBlockTimestamp() + 26 hours);
        clone = exec.nextClone(id);
        IExecutorV1.Call[] memory k4 = _one(_pay(XETH, 100e6, _fair(XETH, 100e6, 10_000), clone));
        assertEq(_refusedWith(id, 100e6, k4), IEvaluatorV1.ReadStale.selector);
    }

    /// Dust across outputs, or a token the mandate did not sign, is nothing:
    /// the firing reverts and nothing leaves the owner.
    function test_r12f_dustOrAnUnsignedTokenIsNothing() public {
        bytes32 id = _register(_outs(XETH, XBTC), 100);
        uint256 before = IERC20(USDT0).balanceOf(principal);
        address clone = exec.nextClone(id);
        IExecutorV1.Call[] memory k5 = _two(_pay(XETH, 50e6, 1, clone), _pay(XBTC, 50e6, 1, clone));
        assertEq(_refusedWith(id, 100e6, k5), GenericExecutorV1.OutputBelowMinimum.selector);
        clone = exec.nextClone(id);
        IExecutorV1.Call[] memory k6 = _one(_pay(USDG, 100e6, _fair(USDG, 100e6, 10_000), clone));
        vm.expectRevert();
        _fire(id, 100e6, k6);
        assertEq(IERC20(USDT0).balanceOf(principal), before);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {
    IAaveOracle,
    IPool,
    IPoolAddressesProvider,
    IPoolDataProvider
} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";

interface IRound {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// Stock deployment, real X Layer prices and round sources, local routing fixture.
contract V1Confirmation3ForkTest is Test {
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant USDC = 0xB6CEceAB302E2E4948951eE7843FC24E92933061;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant A_USDT0 = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    DeployV1.Deployed internal d;
    address internal principal = address(0xA11CE);
    address internal agent = address(0xA6E);
    address internal enforcer = address(0xE0);

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), 70_752_723);
        d = new DeployV1().deployWith(address(this), address(0), enforcer, 0);
        d.registry.acceptOwnership();
    }

    function test_controlStockDeploymentBindsAllSixExactFeeds() public view {
        address[6] memory tokens = [
            XETH,
            USDT0,
            0xB6CEceAB302E2E4948951eE7843FC24E92933061,
            0xb7C00000bcDEeF966b20B3D884B98E64d2b06b4f,
            0xe538905cf8410324e03A5A23C1c177a474D59b2b,
            0x505000008DE8748DBd4422ff4687a4FC9bEba15b
        ];
        address[6] memory feeds = [
            0x8b85b50535551F8E8cDAF78dA235b5Cf1005907b,
            0xb928a0678352005a2e51F614efD0b54C9830dB80,
            0xB8a08c178D96C315FbFB5661ABD208477391BC40,
            0x4D6f6488a2B3a5f7b088f276887f608a1e9805c4,
            0x4Ff345b18a2bF894F8627F41501FBf30d5C5e7BE,
            0xF959E1B5cA535C28aD24F7f672Bf1A93900810cF
        ];
        for (uint256 i; i < tokens.length; ++i) {
            (bytes32 id, address feed) = d.registry.priceRound(tokens[i]);
            assertEq(feed, feeds[i]);
            (IDescriptors.Descriptor memory descriptor, bool listed, bool revoked) =
                d.registry.descriptorOf(id);
            assertTrue(listed);
            assertFalse(revoked);
            assertEq(descriptor.target, feeds[i]);
            // Round 9: every X Layer feed has a 24 h heartbeat (Chainlink's
            // directory); 25 h for all six (was 1 h, and 24 h for the stables).
            assertEq(descriptor.maxAge, 25 hours);
            assertEq(uint256(descriptor.freshness), uint256(IDescriptors.Freshness.ChainlinkRound));
            assertEq(descriptor.word, 1);
            assertTrue(descriptor.isSigned && descriptor.mustBePositive);
        }
        assertEq(d.registry.owner(), address(this));
    }

    function _position(bool stable) internal returns (bytes32 id, bytes memory route, uint256 out) {
        address tokenIn = stable ? USDC : XETH;
        uint256 amount = stable ? 1e6 : 0.001e18;
        address source = A_XETH;
        if (stable) {
            IPoolAddressesProvider provider = IPoolAddressesProvider(IPool(POOL).ADDRESSES_PROVIDER());
            (source,,) = IPoolDataProvider(provider.getPoolDataProvider()).getReserveTokensAddresses(USDC);
        }
        MockRouter router = new MockRouter();
        vm.prank(source);
        IERC20(tokenIn).transfer(principal, amount);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(address(router), 100e6);
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(router), address(router));
        c.sweepSet = new address[](0);
        c.tokenOut = USDT0;
        c.oracle = ORACLE;
        c.rateKind = uint8(GenericExecutorV1.RateKind.Oracle);
        c.maxSlippageBps = 50;
        c.prices = PinnedPrices.pin(IShieldRegistryV1(address(d.registry)), tokenIn, USDT0);
        IShieldV1.MandateParams memory p;
        p.agent = agent;
        p.executor = address(d.generic);
        p.evaluator = address(d.evaluator);
        p.asset = tokenIn;
        p.maxTransactionValue = amount;
        p.maxCumulativeValue = amount;
        p.validUntil = uint48(block.timestamp + 30 days);
        p.action = d.generic.ACTION_TRANSFORM();
        p.actionConfig = abi.encode(uint8(1), c);
        vm.startPrank(principal);
        IERC20(tokenIn).approve(address(d.shield), amount);
        id = d.shield.registerMandate(p);
        vm.stopPrank();
        out = amount * IAaveOracle(ORACLE).getAssetPrice(tokenIn) * 1e6
            / (IAaveOracle(ORACLE).getAssetPrice(USDT0) * (stable ? 1e6 : 1e18));
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = IExecutorV1.Call(
            address(router),
            address(router),
            tokenIn,
            amount,
            false,
            abi.encodeCall(MockRouter.swap, (tokenIn, amount, USDT0, out, principal))
        );
        route = abi.encode(calls);
    }

    function test_controlStockDeploymentFreshPriceFiringSucceeds() public {
        (bytes32 id, bytes memory route, uint256 out) = _position(true);
        vm.prank(agent);
        assertEq(d.shield.fire(id, 1e6, route), 1e6);
        assertEq(IERC20(USDT0).balanceOf(principal), out);
    }

    /// Fix round 9 (was test_controlStockDeploymentRefusesStaleXethAtPinnedBlock):
    /// the historical xETH round is 6,143 seconds old, a current price for a
    /// feed with a 24 h heartbeat. The 1 h limit refused it; 25 h accepts it
    /// and still refuses a round one second past 25 h.
    function test_fixStockDeploymentAcceptsCurrentXethAndRefusesPast25Hours() public {
        (bytes32 id, bytes memory route, uint256 out) = _position(false);
        (,,, uint256 updatedAt,) = IRound(0x8b85b50535551F8E8cDAF78dA235b5Cf1005907b).latestRoundData();
        uint256 pinned = block.timestamp;
        vm.warp(updatedAt + 25 hours + 1);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0)
            )
        );
        d.shield.fire(id, 0.001e18, route);
        vm.warp(pinned);
        vm.prank(agent);
        assertEq(d.shield.fire(id, 0.001e18, route), 0.001e18);
        assertEq(IERC20(USDT0).balanceOf(principal), out);
        assertEq(d.shield.getMandate(id).firings, 1);
    }

    /// Fix round 4 (was test_gap...): the admin clearing both bindings no longer reaches the
    /// live mandate; it keeps the stale-price refusal it was admitted with.
    function test_fixStockDeploymentAdminClearingDoesNotReachLivePriceGates() public {
        (bytes32 id, bytes memory route, uint256 out) = _position(true);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0)
            )
        );
        d.shield.fire(id, 1e6, route);
        assertEq(d.shield.getMandate(id).firings, 0);
        d.registry.setPriceRound(USDC, bytes32(0), address(0));
        d.registry.setPriceRound(USDT0, bytes32(0), address(0));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0)
            )
        );
        d.shield.fire(id, 1e6, route);
        assertEq(d.shield.getMandate(id).firings, 0);
        assertEq(d.shield.getMandate(id).revision, 1);
        assertEq(IERC20(USDT0).balanceOf(principal), 0);
        out;
    }
}

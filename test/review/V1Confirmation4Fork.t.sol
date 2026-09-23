// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Shield v1 on a fork of X Layer: the Aave adapter on the v1 interface, driven
/// through the v1 core with a health-factor trigger tree read through the
/// descriptor catalog. Same fixture as the v0.1 fork test (block 70,752,723,
/// xETH collateral, USD-T0 debt, health factor about 1.5).
/// RPC: `XLAYER_RPC_URL`, defaulting to the public endpoint.
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveOracle, IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {AaveV3AdapterV1} from "contracts/v1/AaveV3AdapterV1.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IEvaluatorV1} from "contracts/v1/interfaces/IEvaluatorV1.sol";

import {MockFeed} from "test/v1/mocks/MockCatalog.sol";

/// Independent C1 consumer confirmation. Shared fixture from V1FixFollowupFork; no inherited tests.
contract V1Confirmation4ForkTest is Test {
    uint256 internal constant FORK_BLOCK = 70_752_723;
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant XETH = 0xE7B000003A45145decf8a28FC755aD5eC5EA025A;
    address internal constant A_XETH = 0xe6639ba6c1d79Be6d4c776E4c17504538d1719cD;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant A_USDT0 = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    address internal constant V_USDT0 = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;
    bytes32 internal constant SUPPLY = keccak256("aave-v3.supply");
    bytes32 internal constant REPAY = keccak256("aave-v3.repay");
    bytes32 internal constant RWC = keccak256("aave-v3.repayWithCollateral");

    ShieldV1 internal shield;

    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    AaveV3AdapterV1 internal adapter;
    MockRouter internal router;
    IPool internal pool = IPool(POOL);
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    uint256 internal constant COLLATERAL = 0.05e18;
    uint256 internal constant DEBT = 60e6;
    uint48 internal validUntil;
    bytes32 internal dHf; // aave.accountData.hf

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        assertEq(block.chainid, 196);
        validUntil = uint48(vm.getBlockTimestamp() + 30 days);
        registry = new ShieldRegistryV1(address(this));
        shield = new ShieldV1(registry, 10);
        ev = new ExpressionEvaluator(registry);
        adapter = new AaveV3AdapterV1(address(shield), pool);
        router = new MockRouter();
        registry.setExecutor(address(adapter), true);
        registry.setEvaluator(address(ev), true);
        dHf = registry.listDescriptor(
            IDescriptors.Descriptor({
                kind: IDescriptors.DescriptorKind.PerAddress,
                target: POOL,
                selector: IPool.getUserAccountData.selector,
                argCount: 1,
                subjectArg: 0,
                subjectRule: IDescriptors.SubjectRule.PrincipalRequired,
                word: 5,
                isSigned: false,
                mustBePositive: false,
                decimals: 18,
                freshness: IDescriptors.Freshness.None,
                maxAge: 0,
                gasStipend: 500_000,
                copyBytes: 192
            })
        );
        vm.prank(A_XETH);
        IERC20(XETH).transfer(principal, 1e18);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(principal, 100e6);
        vm.prank(A_USDT0);
        IERC20(USDT0).transfer(address(router), 10_000e6);
        vm.startPrank(principal);
        IERC20(XETH).approve(POOL, type(uint256).max);
        pool.supply(XETH, COLLATERAL, principal, 0);
        pool.borrow(USDT0, DEBT, 2, 0, principal);
        IERC20(USDT0).approve(address(shield), type(uint256).max);
        IERC20(A_XETH).approve(address(shield), type(uint256).max);
        IERC20(XETH).approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- helpers

    function _healthFactor(address user) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(user);
    }

    /// health factor of the principal < threshold, as a v1 tree through the catalog
    function _hfBelow(uint256 threshold) internal view returns (bytes memory) {
        ExprLib.Read[] memory r = new ExprLib.Read[](1);
        r[0] = ExprLib.Read({
            descriptor: dHf,
            target: POOL,
            args: abi.encode(principal),
            subject: ExprLib.Subject.Principal,
            decimals: 18
        });
        ExprLib.Node[] memory n = new ExprLib.Node[](3);
        n[0] = ExprLib.Node({kind: uint8(ExprLib.Kind.READ), a: 0, b: 0});
        n[1] = ExprLib.Node({kind: uint8(ExprLib.Kind.CONST), a: threshold, b: 0});
        n[2] = ExprLib.Node({kind: uint8(ExprLib.Kind.LT), a: 0, b: 1});
        return abi.encode(r, n);
    }

    function _params(bytes32 action, address asset, uint256 txCap, uint256 lifetime, bytes memory trigger)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        p.agent = agent;
        p.executor = address(adapter);
        p.evaluator = address(ev);
        p.action = action;
        p.asset = asset;
        p.maxTransactionValue = txCap;
        p.maxCumulativeValue = lifetime;
        p.validFrom = 0;
        p.validUntil = validUntil;
        p.maxFeeBps = 10;
        p.funding = uint8(IShieldV1.FundingMode.PULL);
        p.trigger = trigger;
    }

    function _register(IShieldV1.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(p);
    }

    function _swapCalldata(uint256 amountIn, uint256 amountOut, address to)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(MockRouter.swap, (XETH, amountIn, USDT0, amountOut, to));
    }

    function _fairUsdt0(uint256 xethAmount) internal view returns (uint256) {
        IAaveOracle oracle = IAaveOracle(ORACLE);
        return (xethAmount * oracle.getAssetPrice(XETH) * 1e6) / (oracle.getAssetPrice(USDT0) * 1e18);
    }

    function _rwcConfig(uint256 targetHf) internal view returns (bytes memory) {
        return abi.encode(
            uint8(1),
            AaveV3AdapterV1.RepayWithCollateralConfig({
                collateral: XETH,
                debtAsset: USDT0,
                targetHealthFactor: targetHf,
                maxSlippageBps: 100,
                slippageOverride: false,
                router: address(router),
                spender: address(router),
                prices: PinnedPrices.pin(IShieldRegistryV1(address(registry)), XETH, USDT0)
            })
        );
    }

    function _assertNothingLeftBehind() internal view {
        assertEq(IERC20(XETH).balanceOf(address(adapter)), 0, "adapter xETH");
        assertEq(IERC20(USDT0).balanceOf(address(adapter)), 0, "adapter USDT0");
        assertEq(IERC20(A_XETH).balanceOf(address(adapter)), 0, "adapter aXETH");
        assertEq(IERC20(USDT0).balanceOf(address(shield)), 0, "shield USDT0");
        assertEq(IERC20(XETH).allowance(address(adapter), address(router)), 0, "approval xETH->spender");
    }

    function _bindRound(address token, address feed) internal returns (bytes32 id) {
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = feed;
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.word = 1;
        d.isSigned = true;
        d.mustBePositive = true;
        d.decimals = 8;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = 86_400;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
        id = registry.listDescriptor(d);
        registry.setPriceRound(token, id, feed);
    }

    function _oldRuleStopsFiring(bool collateral, bool revoked) internal {
        address token = collateral ? XETH : USDT0;
        address feed = collateral
            ? 0x8b85b50535551F8E8cDAF78dA235b5Cf1005907b
            : 0xb928a0678352005a2e51F614efD0b54C9830dB80;
        bytes32 descriptor = _bindRound(token, feed);
        IShieldV1.MandateParams memory p = _params(RWC, A_XETH, 0.01e18, 0.02e18, "");
        p.actionConfig = _rwcConfig(1e18);
        bytes32 id = _register(p);
        uint256 sold = 0.0005e18;
        bytes memory route = _swapCalldata(sold, _fairUsdt0(sold), address(adapter));
        bytes memory expected;
        if (revoked) {
            address enforcer = address(0xE0);
            registry.setEnforcer(enforcer, true);
            vm.prank(enforcer);
            registry.revokeDescriptor(descriptor);
            MockFeed replacement = new MockFeed();
            replacement.set(1, 1e8, vm.getBlockTimestamp(), 1);
            _bindRound(token, address(replacement));
            expected = abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked");
        } else {
            vm.warp(vm.getBlockTimestamp() + 25 hours);
            registry.setPriceRound(token, bytes32(0), address(0));
            expected = abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0);
        }
        uint256 debtBefore = IERC20(V_USDT0).balanceOf(principal);
        uint256 sharesBefore = IERC20(A_XETH).balanceOf(principal);
        uint256 routerBalance = IERC20(USDT0).balanceOf(address(router));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, expected
            )
        );
        shield.fire(id, 0.008e18, route);
        assertEq(IERC20(V_USDT0).balanceOf(principal), debtBefore);
        assertEq(IERC20(A_XETH).balanceOf(principal), sharesBefore);
        assertEq(IERC20(USDT0).balanceOf(address(router)), routerBalance);
        assertEq(shield.getMandate(id).cumulativeUsed, 0);
        assertEq(shield.getMandate(id).firings, 0);
        assertEq(shield.getMandate(id).revision, 1);
        _assertNothingLeftBehind();
    }

    function test_aaveKeepsSignedCollateralFreshnessAfterAdminClear() public {
        _oldRuleStopsFiring(true, false);
    }

    function test_aaveKeepsSignedDebtAssetFreshnessAfterAdminClear() public {
        _oldRuleStopsFiring(false, false);
    }

    function test_aaveFreshReplacementCannotSkipRevokedSignedDescriptor() public {
        _oldRuleStopsFiring(false, true);
    }
}

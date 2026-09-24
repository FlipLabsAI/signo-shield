// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockFeed} from "test/v1/mocks/MockCatalog.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IDescriptors} from "contracts/v1/interfaces/IDescriptors.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {DisposableCloneV1} from "contracts/v1/DisposableCloneV1.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {MockFeeToken, MockToken} from "test/v1/mocks/MockExecutor.sol";
import {MockDex, MockOracle, MockVault, MockMarket} from "test/v1/mocks/MockVenues.sol";

abstract contract R1112GenericFixture is Test {
    ShieldV1 internal shield;
    ShieldRegistryV1 internal registry;
    ExpressionEvaluator internal ev;
    GenericExecutorV1 internal exec;
    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal mid; // an intermediate token a route can leave behind
    MockDex internal dex;
    MockOracle internal oracle;
    MockVault internal vault;
    MockMarket internal market;

    address internal admin = address(0xAD);
    address internal enforcer = address(0xE0);
    address internal principal = address(0xA11CE);
    address internal agent = address(0xA6E);
    bytes32 internal dDebt;
    bytes32 internal dColl;
    bytes32 internal constant TRANSFORM = keccak256("generic.transform");
    bytes32 internal constant TRANSFER = keccak256("generic.transfer");
    bytes32 internal constant REDEEM = keccak256("generic.redeem");
    bytes32 internal constant REPAY = keccak256("generic.repay");

    function setUp() public {
        registry = new ShieldRegistryV1(admin);
        shield = new ShieldV1(registry, 0);
        ev = new ExpressionEvaluator(registry);
        exec = new GenericExecutorV1(address(shield));
        usdc = new MockToken();
        weth = new MockToken();
        mid = new MockToken();
        dex = new MockDex();
        oracle = new MockOracle();
        vault = new MockVault(IERC20(address(usdc)));
        market = new MockMarket(IERC20(address(usdc)));
        oracle.set(address(usdc), 1e8);
        oracle.set(address(weth), 1e8); // 1:1 for readable numbers
        vm.startPrank(admin);
        registry.setEnforcer(enforcer, true);
        registry.setExecutor(address(exec), true);
        registry.setEvaluator(address(ev), true);
        dDebt = registry.listDescriptor(_shape(bytes4(keccak256("balanceOf(address)")))); // the debt token's balance
        dColl = registry.listDescriptor(_shape(bytes4(keccak256("collateralOf(address)"))));
        vm.stopPrank();
        usdc.mint(principal, 1_000_000e18);
        vm.prank(principal);
        usdc.approve(address(shield), type(uint256).max);
    }

    function _shape(bytes4 sel) internal pure returns (IDescriptors.Descriptor memory) {
        return IDescriptors.Descriptor({
            kind: IDescriptors.DescriptorKind.Shape,
            target: address(0),
            selector: sel,
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
            copyBytes: 32,
            unboundedTop: false
        });
    }

    function _cfg() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(dex), spender: address(dex)});
        c.sweepSet = new address[](1);
        c.sweepSet[0] = address(mid);
        c.tokenOut = address(weth);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Oracle);
        c.oracle = address(oracle);
        c.maxSlippageBps = 50;
    }

    function _params(bytes32 action, address asset, GenericExecutorV1.Config memory c, uint8 funding)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        // An Oracle transform signs the registry's price rules. This suite binds no round, so
        // the rules are the explicit no-round mode. Built without external calls, so a
        // `vm.prank` or `vm.expectRevert` placed before `registerMandate(_params(...))` still
        // reaches the registration.
        ExprLib.PriceRound[] memory given = c.prices;
        if (
            action == TRANSFORM && c.rateKind == uint8(GenericExecutorV1.RateKind.Oracle) && given.length == 0
        ) {
            c.prices = new ExprLib.PriceRound[](2);
            c.prices[0] = ExprLib.PriceRound(asset, bytes32(0), address(0));
            c.prices[1] = ExprLib.PriceRound(c.tokenOut, bytes32(0), address(0));
        }
        p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(exec),
            evaluator: address(ev),
            asset: asset,
            maxTransactionValue: 1_000e18,
            maxCumulativeValue: 10_000e18,
            validFrom: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 0,
            funding: funding,
            action: action,
            actionConfig: abi.encode(uint8(1), c),
            trigger: "",
            outcome: ""
        });
        c.prices = given;
    }

    function _swapCall(uint256 amountIn, address to) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call({
            target: address(dex),
            spender: address(dex),
            approveToken: address(usdc),
            approveAmount: amountIn,
            claimStep: false,
            data: abi.encodeCall(MockDex.swap, (address(usdc), address(weth), amountIn, to))
        });
    }

    function _route(IExecutorV1.Call memory k) internal pure returns (bytes memory) {
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](1);
        calls[0] = k;
        return abi.encode(calls);
    }

    // ---------------------------------------------------------------- transform

    /// Round 7: a token no mandate declared, left in a used sandbox (paid by a venue
    /// after the firing, or never in the sweep set), reaches the owner and no one else.

    // ----------------------------------------------------------------- transfer

    /// Round 8: a transfer signs no venue. Before, it had to sign one (with code) that it
    /// never calls, so a transfer to a wallet could not be registered without a decoy.

    // ------------------------------------------------------------------- redeem

    function _vaultShares(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(principal);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, principal);
        vault.approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    function _redeemCfg() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(vault), spender: address(0)});
        c.sweepSet = new address[](0);
        c.tokenOut = address(usdc);
        c.maxSlippageBps = 50;
        c.signedShares = 1_000e18; // the sample: the size of the position these tests redeem
        c.signedAssets = vault.convertToAssets(c.signedShares);
        c.sanityBandBps = 500;
    }

    function _redeemRoute(uint256 shares, address clone) internal view returns (bytes memory) {
        return _route(
            IExecutorV1.Call({
                target: address(vault),
                spender: address(0),
                approveToken: address(0),
                approveAmount: 0,
                claimStep: false,
                data: abi.encodeCall(IERC4626.redeem, (shares, clone, clone))
            })
        );
    }

    /// Round 7: the floor keeps only its lower edge at a firing, so a vault that grew
    /// (here a 20% donation) is withdrawn from, and the owner receives the grown value.

    /// The owner's floor refuses a withdrawal once the sample is worth more than the
    /// band below its value at signing (here a 20% loss against a 5% band).

    /// No floor (the default the app signs): a withdrawal at a loss goes through, paid at
    /// the vault's own quote less the slippage, into the owner's wallet only.

    /// Without a floor nothing about a sample may be signed: no decorative numbers.

    // -------------------------------------------------------------------- repay

    function _repayCfg() internal view returns (GenericExecutorV1.Config memory c) {
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue({target: address(market), spender: address(market)});
        c.sweepSet = new address[](0);
        c.tokenOut = address(usdc);
        c.market = address(market);
        c.collateralTarget = address(market);
        c.maxSlippageBps = 10;
        c.debtDescriptor = dDebt;
        c.collateralDescriptor = dColl;
    }

    function _repayCall(uint256 amount) internal view returns (IExecutorV1.Call memory) {
        return IExecutorV1.Call({
            target: address(market),
            spender: address(market),
            approveToken: address(usdc),
            approveAmount: amount,
            claimStep: false,
            data: abi.encodeCall(MockMarket.repay, (principal, amount))
        });
    }

    // ------------------------------------------- round 12: any of several outputs

    /// A second output token at twice weth's price, so the value sums are not 1:1.
    function _wbtc() internal returns (MockToken wbtc) {
        wbtc = new MockToken();
        oracle.set(address(wbtc), 2e8);
        _review(address(weth));
        _review(address(wbtc));
    }

    /// Round 13 (G12-H2): several outputs must be tokens the registry bound a
    /// fresh round for. Bind one for `token` (a mock Chainlink feed, fresh now).
    function _review(address token) internal {
        MockFeed f = new MockFeed();
        f.set(1, 1e8, vm.getBlockTimestamp(), 1);
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(f);
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
        vm.startPrank(admin);
        registry.setPriceRound(token, registry.listDescriptor(d), address(f));
        vm.stopPrank();
    }

    /// The signed price rules for [usdc, weth, `out`], as the registry binds them now.
    function _pinned3(address out) internal view returns (ExprLib.PriceRound[] memory) {
        address[] memory t = new address[](3);
        t[0] = address(usdc);
        t[1] = address(weth);
        t[2] = out;
        return PinnedPrices.pin(IShieldRegistryV1(address(registry)), t);
    }

    function _anyCfg(MockToken wbtc, bool floors) internal view returns (GenericExecutorV1.Config memory c) {
        c = _cfg();
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output({token: address(wbtc), floor: floors ? 40e18 : 0});
        if (floors) {
            c.rateKind = uint8(GenericExecutorV1.RateKind.Floor);
            c.rateOrFloor = 100e18; // 100 weth settles a whole firing, or 40 wbtc, or shares of each
            c.oracle = address(0);
            c.maxSlippageBps = 0;
        } else {
            c.prices = _pinned3(address(wbtc));
        }
    }

    function _swapTo(address tokenOut, uint256 amountIn, address to)
        internal
        view
        returns (IExecutorV1.Call memory k)
    {
        k = _swapCall(amountIn, to);
        k.data = abi.encodeCall(MockDex.swap, (address(usdc), tokenOut, amountIn, to));
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

    function _register(GenericExecutorV1.Config memory c) internal returns (bytes32 id) {
        vm.prank(principal);
        id = shield.registerMandate(_params(TRANSFORM, address(usdc), c, 0));
    }

    /// Austin, 24 Sep: a mandate bounds the loss, not the route. The route may
    /// deliver only the second signed output; the oracle judges its value.

    /// A fee-on-transfer output: the value check reads what reached the owner,
    /// after the token's own fee on the sweep, never what the route paid.

    function _refused(GenericExecutorV1.Config memory c, bytes32 action, bytes memory err) internal {
        IShieldV1.MandateParams memory p = _params(action, address(usdc), c, 0);
        vm.prank(principal);
        vm.expectRevert(err);
        shield.registerMandate(p);
    }
}

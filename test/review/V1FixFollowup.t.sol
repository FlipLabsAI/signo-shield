// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockVault} from "test/v1/mocks/MockVenues.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// Honest accounting: debt is an 8-decimal asset priced at $100, accountData is 8-decimal USD.
contract FollowupValueMarket {
    IERC20 public immutable token;
    mapping(address => uint256) public debt;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setDebt(address who, uint256 value) external {
        debt[who] = value;
    }

    function accountData(address who) external view returns (uint256, uint256) {
        return (1_000_000e8, debt[who] * 100);
    }

    function repay(address who, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        debt[who] -= amount;
    }
}

/// Standard ERC-4626 conversion/withdrawal, with the existing fixture's exit fee.
contract FollowupOffsetVault is MockVault {
    constructor(IERC20 underlying) MockVault(underlying) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }
}

contract V1FixFollowupTest is V1ReviewBase {
    /// R2 (fixed): the debt read must be the balance of a debt token that declares the asset.
    function test_fixRepayRefusesADebtReadThatIsNotTheDebtTokenBalance() public {
        MockERC20 btc = new MockERC20("Eight decimal asset", "EIGHT", 8);
        FollowupValueMarket m = new FollowupValueMarket(IERC20(address(btc)));
        btc.mint(principal, 1_000e8);
        vm.prank(principal);
        btc.approve(address(core), 1_000e8);
        m.setDebt(principal, 1_000e8);
        IDescriptors.Descriptor memory d = _descriptor(FollowupValueMarket.accountData.selector);
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(m);
        d.copyBytes = 64;
        d.decimals = 8;
        bytes32 collateral = registry.listDescriptor(d);
        d.word = 1;
        bytes32 debt = registry.listDescriptor(d);
        GenericExecutorV1.Config memory c = _repayConfig();
        c.venues = new GenericExecutorV1.Venue[](2);
        c.venues[0] = GenericExecutorV1.Venue(address(m), address(m));
        c.venues[1] = GenericExecutorV1.Venue(address(dex), address(dex));
        c.tokenOut = address(btc);
        c.market = address(m);
        c.collateralTarget = address(m);
        c.debtDescriptor = debt;
        c.collateralDescriptor = collateral;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), c);
        p.asset = address(btc);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "repay:units"));
        core.registerMandate(p);
    }

    /// R5 (open, claims unlisted at launch): a false-labelled claim may still carry an approval.
    /// Closed by the signed per-venue claim recipe (v1.1, with the Pendle venue review).
    function test_knownGapComposeUnlabelledClaimCanStillCarryApprovalAndHideGrossRewards() public {
        MockDistributor second = new MockDistributor(reward);
        distributor.setOwed(principal, 100e18);
        second.setOwed(principal, 100e18);
        second.setDrain(9_900);
        ClaimExecutorV1.Config memory c = _claimConfig(true);
        c.venues = new ClaimExecutorV1.Venue[](3);
        c.venues[0] = ClaimExecutorV1.Venue(address(distributor), address(0));
        c.venues[1] = ClaimExecutorV1.Venue(address(second), address(second));
        c.venues[2] = ClaimExecutorV1.Venue(address(dex), address(dex));
        bytes32 id = _register(_claimParams(true, c));
        address clone = claims.nextClone(id);
        IExecutorV1.Call[] memory calls = new IExecutorV1.Call[](3);
        calls[0] = _claim(principal, clone, true);
        calls[1] = IExecutorV1.Call(
            address(second),
            address(second),
            address(reward),
            99e18,
            false,
            abi.encodeCall(MockDistributor.claim, (principal, clone))
        );
        calls[2] = _swap(address(reward), 101e18, clone);
        _fire(id, 0, abi.encode(calls));
        assertEq(output.balanceOf(principal), 101e18);
        assertEq(reward.balanceOf(address(0xBAD)), 99e18);
        assertEq(distributor.claimable(principal) + second.claimable(principal), 0);
        assertEq(reward.balanceOf(clone), 0);
        assertEq(reward.allowance(clone, address(second)), 0);
    }

    function _vaultParams(address vault, address underlying, uint256 sampleShares)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(vault, address(0));
        c.sweepSet = new address[](0);
        c.tokenOut = underlying;
        c.signedShares = sampleShares;
        c.signedAssets = IERC4626(vault).convertToAssets(sampleShares);
        c.sanityBandBps = 100;
        c.maxSlippageBps = 50;
        p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = vault;
    }

    /// R1 (fixed): the minimum is the exact pre-call quote of the pulled amount.
    function test_fixRedeemExactQuoteRefusesThirtyPercentExitFee() public {
        MockERC20 usd = new MockERC20("USD", "USD", 6);
        FollowupOffsetVault vault = new FollowupOffsetVault(IERC20(address(usd)));
        uint256 deposit = 1_000_000_000_000e6;
        usd.mint(principal, deposit);
        vm.startPrank(principal);
        usd.approve(address(vault), deposit);
        vault.deposit(deposit, principal);
        vm.stopPrank();
        // Model a loss that happened before signing. No repricing occurs during this firing.
        uint256 remainingAssets = 1_500_000_000_000;
        vm.prank(address(vault));
        usd.transfer(address(0xD00D), deposit - remainingAssets);
        vault.setExitFee(3_000);
        uint256 shares = 100_000_000_000e18;
        uint256 preCallQuote = vault.convertToAssets(shares);
        assertEq(preCallQuote, 150_000e6);
        assertEq(vault.convertToAssets(1e18), 1, "single-unit quote truncates 1.5 to 1");
        IShieldV1.MandateParams memory p = _vaultParams(address(vault), address(usd), shares);
        p.maxTransactionValue = shares;
        p.maxCumulativeValue = shares;
        vm.prank(principal);
        vault.approve(address(core), shares);
        bytes32 id = _register(p);
        address clone = generic.nextClone(id);
        IExecutorV1.Call memory call_ = IExecutorV1.Call(
            address(vault),
            address(0),
            address(0),
            0,
            false,
            abi.encodeWithSignature("redeem(uint256,address,address)", shares, principal, clone)
        );
        vm.expectRevert();
        _fire(id, shares, _route(call_));
        assertEq(usd.balanceOf(principal), 0);
        assertEq(vault.balanceOf(principal), 1_000_000_000_000e18);
    }

    /// R1 (resolved): the independent basis of a redemption is the signed conversion and its
    /// band; an oracle cannot be signed into a redeem config, so none is implied.
    function test_fixRedeemSignsNoOracle() public {
        MockVault vault = new MockVault(IERC20(address(asset)));
        vm.startPrank(principal);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, principal);
        vault.approve(address(core), 100e18);
        vm.stopPrank();
        IShieldV1.MandateParams memory p = _vaultParams(address(vault), address(asset), 1e18);
        GenericExecutorV1.Config memory c;
        (, c) = abi.decode(p.actionConfig, (uint8, GenericExecutorV1.Config));
        c.oracle = address(oracle);
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:oracle"));
        core.registerMandate(p);
    }

    /// R6 (fixed): an unchanged action config keeps its admitted reads through a delisting.
    function test_fixRecipeDelistingDoesNotBlockUnchangedCapAmendment() public {
        market.setDebt(principal, 500e18);
        market.setCollateral(principal, 1_000e18);
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), _repayConfig());
        bytes32 id = _register(p);
        registry.delistDescriptor(debtId);
        p.maxTransactionValue = 500e18;
        vm.prank(principal);
        core.amendMandate(id, p);
        assertEq(core.getMandate(id).maxTransactionValue, 500e18);
        assertEq(_fire(id, 100e18, _route(_repayCall(100e18))), 100e18);
    }

    /// R7 (fixed): a round's answer must be positive whichever word the descriptor selects.
    function test_fixRoundAnswerMustBePositiveWhicheverWordIsRead() public {
        MockFeed feed = new MockFeed();
        feed.set(7, -1, vm.getBlockTimestamp(), 7);
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(feed);
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = 3_600;
        d.mustBePositive = true;
        d.word = 0; // positive roundId, while the required answer field is negative
        bytes32 descriptor = registry.listDescriptor(d);
        ExprLib.Read[] memory reads = new ExprLib.Read[](1);
        reads[0] = ExprLib.Read(descriptor, address(feed), "", ExprLib.Subject.None, 0);
        ExprLib.Node[] memory nodes = new ExprLib.Node[](3);
        nodes[0] = ExprLib.Node(uint8(ExprLib.Kind.READ), 0, 0);
        nodes[1] = ExprLib.Node(uint8(ExprLib.Kind.CONST), 0, 0);
        nodes[2] = ExprLib.Node(uint8(ExprLib.Kind.GT), 0, 1);
        IShieldV1.MandateParams memory p = _mockParams();
        p.trigger = abi.encode(reads, nodes);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.ReadNotPositive.selector, 0));
        core.registerMandate(p);
    }

    /// R8 (fixed): capture and snapshot bind the principal like judgement does.
    function test_fixCaptureAndSnapshotBindThePrincipal() public {
        bytes memory signedTree = _tree(address(asset), balanceId, ExprLib.Kind.SIGNED, 18);
        bytes memory beforeTree = _tree(address(asset), balanceId, ExprLib.Kind.BEFORE, 18);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        evaluator.capture(signedTree, recipient);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.SubjectMismatch.selector, 0));
        evaluator.snapshot(beforeTree, recipient);
        assertEq(evaluator.capture(signedTree, principal)[0], 1_000_000e18);
    }

    function test_controlRepayBlockedRecipeTargetAndRevokedDescriptorRollback() public {
        market.setDebt(principal, 500e18);
        market.setCollateral(principal, 1_000e18);
        bytes32 id = _register(_genericParams(generic.ACTION_REPAY(), _repayConfig()));
        uint256 before = asset.balanceOf(principal);
        vm.prank(enforcer);
        registry.suspend(address(market));
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        _fire(id, 100e18, _route(_repayCall(100e18)));
        assertEq(asset.balanceOf(principal), before);
        vm.prank(enforcer);
        registry.revokeDescriptor(debtId);
        vm.expectRevert(abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked"));
        _fire(id, 100e18, _route(_repayCall(100e18)));
        assertEq(core.getMandate(id).firings, 0);
    }

    function test_controlFullRepaymentStillPassesPrePullSnapshot() public {
        market.setDebt(principal, 500e18);
        market.setCollateral(principal, 1_000e18);
        bytes32 id = _register(_genericParams(generic.ACTION_REPAY(), _repayConfig()));
        assertEq(_fire(id, 100e18, _route(_repayCall(100e18))), 100e18);
        assertEq(market.debtOf(principal), 400e18);
        assertEq(market.collateralOf(principal), 1_000e18);
    }

    function test_controlSplitRegistryBindingsAndFreezeReachCore() public {
        assertEq(address(core.registry()), address(registry));
        assertEq(address(evaluator.catalog()), address(registry));
        assertEq(address(generic.registry()), address(registry));
        assertEq(address(claims.registry()), address(registry));
        bytes32 id = _register(_mockParams());
        vm.prank(enforcer);
        registry.freezeAgent(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.MandateBlocked.selector, id, IShieldV1.MandateReason.AGENT_FROZEN
            )
        );
        _fire(id, 1e18, "");
        assertEq(core.getMandate(id).firings, 0);
    }

    /// R9 (fixed): one admin. The registry's owner is the core's admin, so the enforcer
    /// exclusion covers every admin seat there is.
    function test_fixOneAdminForCoreAndRegistry() public {
        registry.transferOwnership(recipient);
        vm.prank(recipient);
        registry.acceptOwnership();
        // The previous owner is nobody now: not admin of the core either.
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.NotAdmin.selector));
        core.setFeeBps(5);
        vm.prank(recipient);
        core.setFeeBps(5);
        assertEq(core.feeBps(), 5);
        // The one admin cannot be an enforcer.
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IShieldRegistryV1.AdminCannotBeEnforcer.selector, recipient));
        registry.setEnforcer(recipient, true);
    }
}

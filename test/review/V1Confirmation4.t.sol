// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {MockVault} from "test/v1/mocks/MockVenues.sol";
import {EntryFeeVault} from "./V1Round4.t.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ReviewRepricingVault} from "./V1ReviewActions.t.sol";

/// Independent delta/boundary review of production head 1e090b6.
/// Production code is unchanged. Claims are explicitly listed only in this local fixture.
contract V1Confirmation4Test is V1ReviewBase {
    function _bind(address token) internal returns (MockFeed feed, bytes32 id) {
        feed = new MockFeed();
        feed.set(7, 1e8, vm.getBlockTimestamp(), 7);
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(feed);
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.word = 1;
        d.isSigned = true;
        d.mustBePositive = true;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = 3600;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
        id = registry.listDescriptor(d);
        registry.setPriceRound(token, id, address(feed));
    }

    function _expectedOutcome(bytes32 id, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, reason
            )
        );
    }

    function _swapRoute() internal view returns (bytes memory) {
        return _route(_swap(address(asset), 100e18, principal));
    }

    function test_capOnlyAmendmentKeepsPinnedFreshnessAfterAdminClear() public {
        (MockFeed feed,) = _bind(address(asset));
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        bytes32 id = _register(p);
        bytes32 signedConfig = keccak256(p.actionConfig);
        registry.setPriceRound(address(asset), bytes32(0), address(0));
        p.maxCumulativeValue += 1e18;
        vm.prank(principal);
        core.amendMandate(id, p);
        assertEq(keccak256(core.getMandate(id).actionConfig), signedConfig);
        assertEq(core.getMandate(id).revision, 2);
        feed.set(8, 1e8, vm.getBlockTimestamp() - 3601, 8);
        bytes memory route = _swapRoute();
        _expectedOutcome(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _fire(id, 100e18, route);
        assertEq(core.getMandate(id).cumulativeUsed, 0);
        assertEq(asset.balanceOf(principal), 1_000_000e18);
    }

    function test_delistingAllowsUnchangedConfigAmendmentButRevocationStillStopsIt() public {
        (, bytes32 descriptor) = _bind(address(asset));
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        bytes32 id = _register(p);
        registry.delistDescriptor(descriptor);
        p.maxCumulativeValue += 1e18;
        vm.prank(principal);
        core.amendMandate(id, p);
        bytes memory route = _swapRoute();
        assertEq(_fire(id, 100e18, route), 100e18);
        vm.prank(enforcer);
        registry.revokeDescriptor(descriptor);
        _expectedOutcome(id, abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked"));
        _fire(id, 100e18, route);
        assertEq(core.getMandate(id).firings, 1);
        assertEq(core.getMandate(id).cumulativeUsed, 100e18);
    }

    function test_freshReplacementCannotBypassRevokedOriginalFeed() public {
        (MockFeed oldFeed,) = _bind(address(asset));
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        _bind(address(asset)); // entirely different, fresh feed and descriptor
        vm.prank(enforcer);
        registry.revoke(address(oldFeed));
        bytes memory route = _swapRoute();
        _expectedOutcome(id, abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        _fire(id, 100e18, route);
        assertEq(core.getMandate(id).firings, 0);
    }

    function testFuzz_replacementDoesNotHideBadSignedRound(uint8 seed) public {
        (MockFeed oldFeed,) = _bind(address(asset));
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        _bind(address(asset));
        uint256 mode = bound(seed, 0, 4);
        uint256 now_ = vm.getBlockTimestamp();
        if (mode == 0) oldFeed.set(7, 1e8, now_ - 3601, 7);
        if (mode == 1) oldFeed.set(7, 1e8, now_ + 1, 7);
        if (mode == 2) oldFeed.set(7, 1e8, now_, 6);
        if (mode == 3) oldFeed.set(7, 0, now_, 7);
        if (mode == 4) oldFeed.set(7, -1, now_, 7);
        bytes memory route = _swapRoute();
        bytes4 error_ = mode < 3 ? IEvaluatorV1.ReadStale.selector : IEvaluatorV1.ReadNotPositive.selector;
        _expectedOutcome(id, abi.encodeWithSelector(error_, 0));
        _fire(id, 100e18, route);
        assertEq(core.getMandate(id).firings, 0);
        assertEq(asset.balanceOf(principal), 1_000_000e18);
        assertEq(output.balanceOf(principal), 0);
    }

    function test_admissionRejectsMissingExtraAndWrongFeedRules() public {
        _bind(address(asset));
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        (, GenericExecutorV1.Config memory c) = abi.decode(p.actionConfig, (uint8, GenericExecutorV1.Config));
        c.prices = new ExprLib.PriceRound[](0);
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "price:round"));
        core.registerMandate(p);
        c.prices = new ExprLib.PriceRound[](3);
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "price:round"));
        core.registerMandate(p);
        c.prices = _pinned(ExprLib.pair(address(asset), address(output)));
        c.prices[0].feed = address(new MockFeed());
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "price:round"));
        core.registerMandate(p);
    }

    function _smallVault(uint256 sample)
        internal
        returns (MockVault vault, IShieldV1.MandateParams memory p)
    {
        vault = new MockVault(IERC20(address(asset)));
        vm.startPrank(principal);
        asset.approve(address(vault), sample);
        vault.deposit(sample, principal);
        vault.approve(address(core), sample);
        vm.stopPrank();
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(0));
        c.tokenOut = address(asset);
        c.signedShares = sample;
        c.signedAssets = vault.convertToAssets(sample);
        c.sanityBandBps = 100;
        c.maxSlippageBps = 50;
        p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = address(vault);
    }

    function _snapshot(MockVault vault, bytes memory config, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        IExecutorV1.Context memory ctx;
        ctx.principal = principal;
        ctx.asset = address(vault);
        // No external getter here: callers may have armed expectRevert for snapshot itself.
        ctx.action = keccak256("generic.redeem");
        ctx.actionConfig = config;
        return generic.snapshot(ctx, amount);
    }

    function test_samplePrecisionBoundaryIsOneHundredUnderlyingUnits() public {
        (, IShieldV1.MandateParams memory small) = _smallVault(9999);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:precision"));
        core.registerMandate(small);
        (, IShieldV1.MandateParams memory exact) = _smallVault(10_000);
        bytes32 id = _register(exact);
        assertEq(core.getMandate(id).revision, 1);
    }

    function test_lowerBandRoundsInwardBeforeAnyPull() public {
        (MockVault vault, IShieldV1.MandateParams memory p) = _smallVault(10_001);
        bytes32 id = _register(p);
        vm.prank(address(vault));
        asset.transfer(recipient, 101);
        assertEq(vault.convertToAssets(10_001), 9900);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 10_001, 9900));
        _fire(id, 1000, "");
        assertEq(vault.balanceOf(principal), 10_001);
        assertEq(core.getMandate(id).cumulativeUsed, 0);
        // One unit back inside the inward-rounded lower boundary is accepted by the snapshot.
        asset.mint(address(vault), 1);
        assertEq(vault.convertToAssets(10_001), 9901);
        assertEq(_snapshot(vault, p.actionConfig, 1000).length, 32);
    }

    /// Round 7 (Austin, 23 Sep): at a firing the floor keeps only its lower edge, so a
    /// vault that grew past the band is no longer refused; the upper edge applies at signing.
    function test_fixUpperMoveNoLongerRefusesAFiring() public {
        (MockVault vault, IShieldV1.MandateParams memory p) = _smallVault(10_001);
        _register(p);
        asset.mint(address(vault), 102);
        assertEq(vault.convertToAssets(10_001), 10_102);
        _snapshot(vault, p.actionConfig, 1000);
    }

    /// Fuzz the actual snapshot against a cross-multiplied band predicate, not a copy of mulDiv.
    function testFuzz_sampledBandMatchesExactIntegerInequality(uint32 sampleSeed, uint16 moveSeed, bool down)
        public
    {
        uint256 sample = bound(sampleSeed, 10_000, 1_000_000);
        uint256 movement = bound(moveSeed, 0, 300);
        (MockVault vault, IShieldV1.MandateParams memory p) = _smallVault(sample);
        _register(p);
        uint256 shift = sample * movement / 10_000;
        if (down) {
            vm.prank(address(vault));
            asset.transfer(recipient, shift);
        } else {
            asset.mint(address(vault), shift);
        }
        uint256 quote = vault.convertToAssets(sample);
        // Round 7: at a firing only the lower edge applies.
        bool inside = quote * 10_000 >= sample * 9900;
        if (!inside) {
            vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, sample, quote));
        }
        _snapshot(vault, p.actionConfig, 1000);
    }

    function test_postCallSampleBandAlsoStopsAnInCallRepricing() public {
        ReviewRepricingVault vault = new ReviewRepricingVault(address(asset));
        vault.mint(principal, 100e18);
        asset.mint(address(vault), 100e18);
        vm.prank(principal);
        vault.approve(address(core), 100e18);
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(0));
        c.tokenOut = address(asset);
        c.signedShares = 100e18;
        c.signedAssets = 100e18;
        c.sanityBandBps = 100;
        c.maxSlippageBps = 50;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = address(vault);
        bytes32 id = _register(p);
        bytes memory route = _route(
            IExecutorV1.Call(
                address(vault),
                address(0),
                address(0),
                0,
                false,
                abi.encodeCall(vault.redeem, (100e18, principal))
            )
        );
        _expectedOutcome(id, abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 100e18, 1e18));
        _fire(id, 100e18, route);
        assertEq(vault.rate(), 1e18);
        assertEq(vault.balanceOf(principal), 100e18);
        assertEq(core.getMandate(id).firings, 0);
    }

    function _depositSetup(uint256 donated)
        internal
        returns (MockERC20 usd, EntryFeeVault vault, IShieldV1.MandateParams memory p)
    {
        usd = new MockERC20("USD", "USD", 6);
        vault = new EntryFeeVault(IERC20(address(usd)));
        usd.mint(address(this), 1e6 + donated);
        usd.approve(address(vault), 1e6);
        vault.deposit(1e6, address(this));
        usd.transfer(address(vault), donated);
        usd.mint(principal, 100_000e6);
        vm.prank(principal);
        usd.approve(address(core), 100_000e6);
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(vault));
        c.tokenOut = address(vault);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Erc4626);
        c.maxSlippageBps = 50;
        p = _genericParams(generic.ACTION_TRANSFORM(), c);
        p.asset = address(usd);
        p.maxTransactionValue = 100_000e6;
        p.maxCumulativeValue = 100_000e6;
    }

    function _depositRoute(MockERC20 usd, EntryFeeVault vault, uint256 used)
        internal
        view
        returns (bytes memory)
    {
        return _route(
            IExecutorV1.Call(
                address(vault),
                address(vault),
                address(usd),
                used,
                false,
                abi.encodeCall(vault.deposit, (used, principal))
            )
        );
    }

    function test_partialDepositReturnsUnusedInputAndChargesOnlyConsumption() public {
        (MockERC20 usd, EntryFeeVault vault, IShieldV1.MandateParams memory p) = _depositSetup(666_000e6);
        uint256 quote = vault.convertToShares(40_000e6);
        bytes32 id = _register(p);
        assertEq(_fire(id, 100_000e6, _depositRoute(usd, vault, 40_000e6)), 40_000e6);
        assertEq(usd.balanceOf(principal), 60_000e6);
        assertEq(vault.balanceOf(principal), quote);
        assertEq(core.getMandate(id).cumulativeUsed, 40_000e6);
    }

    function test_partialDepositStillRejectsThirtyPercentEntryFee() public {
        (MockERC20 usd, EntryFeeVault vault, IShieldV1.MandateParams memory p) = _depositSetup(666_000e6);
        uint256 quote = vault.convertToShares(100_000e6);
        bytes32 id = _register(p);
        vault.setEntryFee(3000);
        uint256 net = quote * 4 / 10 * 9950 / 10_000;
        uint256 minimum = net - (net / 10_000 + 1);
        uint256 minted = vault.previewDeposit(40_000e6);
        bytes memory route = _depositRoute(usd, vault, 40_000e6);
        _expectedOutcome(
            id, abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, minted, minimum)
        );
        _fire(id, 100_000e6, route);
        assertEq(usd.balanceOf(principal), 100_000e6);
        assertEq(vault.balanceOf(principal), 0);
        assertEq(core.getMandate(id).firings, 0);
    }

    /// Availability observation: the admission-time one-unit gate predates this patch.
    /// Fix round 5 (was test_observation...): the one-unit admission filter is gone; the
    /// vault is admitted and the deposit is priced on the exact amount at firing.
    function test_fixZeroUnitQuoteVaultIsAdmittedAndPricesTheDepositExactly() public {
        (MockERC20 usd, EntryFeeVault vault, IShieldV1.MandateParams memory p) = _depositSetup(2_000_000e6);
        assertEq(vault.convertToShares(1e6), 0);
        uint256 quote = vault.convertToShares(100_000e6);
        assertGt(quote, 49_000);
        vm.prank(principal);
        bytes32 id = core.registerMandate(p);
        bytes memory route = _depositRoute(usd, vault, 100_000e6);
        vm.prank(agent);
        assertEq(core.fire(id, 100_000e6, route), 100_000e6);
        assertEq(vault.balanceOf(principal), quote);
    }
}

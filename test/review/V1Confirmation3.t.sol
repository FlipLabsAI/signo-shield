// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {FollowupOffsetVault} from "./V1FixFollowup.t.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockVault} from "test/v1/mocks/MockVenues.sol";

/// Independent confirmation of 9eae70e. Counterexamples assert the current defect;
/// controls assert expected refusal or success; scope observations are not findings.
/// No production contracts are replaced.
/// Fix round 4: each `test_gap...` is renamed `test_fix...` and now expects the refusal
/// (C1: the mandate keeps the price rule it was admitted with; C2: the band is judged
/// on a signed sample). Setup and counterexample inputs are unchanged.
contract V1Confirmation3Test is V1ReviewBase {
    function _round(MockFeed feed, uint32 age) internal pure returns (IDescriptors.Descriptor memory d) {
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(feed);
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.word = 1;
        d.isSigned = true;
        d.mustBePositive = true;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = age;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
    }

    function _bind(address token, uint32 age) internal returns (MockFeed feed, bytes32 id) {
        feed = new MockFeed();
        feed.set(7, 1e8, vm.getBlockTimestamp(), 7);
        id = registry.listDescriptor(_round(feed, age));
        registry.setPriceRound(token, id, address(feed));
    }

    function _swapMandate() internal returns (bytes32) {
        return _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
    }

    function _swapFire(bytes32 id) internal returns (uint256) {
        return _fire(id, 100e18, _route(_swap(address(asset), 100e18, principal)));
    }

    function _assertNoFiring(bytes32 id) internal view {
        assertEq(core.getMandate(id).firings, 0);
        assertEq(core.getMandate(id).cumulativeUsed, 0);
        assertEq(asset.balanceOf(principal), 1_000_000e18);
        assertEq(output.balanceOf(principal), 0);
    }

    function _expectExecutorRevert(bytes32 id, bytes memory errorData) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, errorData
            )
        );
    }

    function test_controlFreshBoundFeedsAllowOracleTransform() public {
        _bind(address(asset), 3600);
        _bind(address(output), 3600);
        assertEq(_swapFire(_swapMandate()), 100e18);
        assertEq(output.balanceOf(principal), 100e18);
    }

    function test_controlStaleInputAndOutputEachRollback() public {
        (MockFeed inputFeed,) = _bind(address(asset), 3600);
        (MockFeed outputFeed,) = _bind(address(output), 3600);
        bytes32 id = _swapMandate();
        inputFeed.set(7, 1e8, vm.getBlockTimestamp() - 3601, 7);
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _swapFire(id);
        _assertNoFiring(id);
        inputFeed.set(8, 1e8, vm.getBlockTimestamp(), 8);
        outputFeed.set(7, 1e8, vm.getBlockTimestamp() - 3601, 7);
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _swapFire(id);
        _assertNoFiring(id);
    }

    function test_fixAdminClearingFreshnessDoesNotReachALiveMandate() public {
        (MockFeed feed,) = _bind(address(asset), 3600);
        bytes32 id = _swapMandate();
        feed.set(7, 1e8, vm.getBlockTimestamp() - 3601, 7);
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _swapFire(id);
        _assertNoFiring(id);
        registry.setPriceRound(address(asset), bytes32(0), address(0));
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _swapFire(id);
        _assertNoFiring(id);
        assertEq(core.getMandate(id).revision, 1, "owner never amended the mandate");
    }

    function test_fixAdminRelaxingFreshnessAgeDoesNotReachALiveMandate() public {
        (MockFeed feed,) = _bind(address(asset), 3600);
        bytes32 id = _swapMandate();
        feed.set(7, 1e8, vm.getBlockTimestamp() - 7200, 7);
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _swapFire(id);
        bytes32 relaxed = registry.listDescriptor(_round(feed, 86_400));
        registry.setPriceRound(address(asset), relaxed, address(feed));
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0));
        _swapFire(id);
        _assertNoFiring(id);
        assertEq(core.getMandate(id).revision, 1);
    }

    function test_fixClearingBindingKeepsTheRevokedDescriptorStop() public {
        (, bytes32 descriptor) = _bind(address(asset), 3600);
        bytes32 id = _swapMandate();
        vm.prank(enforcer);
        registry.revokeDescriptor(descriptor);
        _expectExecutorRevert(
            id, abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked")
        );
        _swapFire(id);
        registry.setPriceRound(address(asset), bytes32(0), address(0));
        _expectExecutorRevert(
            id, abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "descriptorRevoked")
        );
        _swapFire(id);
        _assertNoFiring(id);
        (,, bool revoked) = registry.descriptorOf(descriptor);
        assertTrue(revoked, "revocation flag remains and the live mandate still consults it");
        assertEq(core.getMandate(id).revision, 1);
    }

    function test_fixClearingBindingKeepsTheSuspendedFeedStop() public {
        (MockFeed feed,) = _bind(address(asset), 3600);
        bytes32 id = _swapMandate();
        vm.prank(enforcer);
        registry.suspend(address(feed));
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        _swapFire(id);
        registry.setPriceRound(address(asset), bytes32(0), address(0));
        _expectExecutorRevert(id, abi.encodeWithSelector(IEvaluatorV1.TreeInvalid.selector, "targetBlocked"));
        _swapFire(id);
        _assertNoFiring(id);
        assertTrue(registry.isSuspended(address(feed)));
    }

    function test_fixDelistedMandatoryPriceDescriptorRefusesNewMandates() public {
        (, bytes32 descriptor) = _bind(address(asset), 3600);
        registry.delistDescriptor(descriptor);
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "price:round"));
        core.registerMandate(p);
        (, bool listed,) = registry.descriptorOf(descriptor);
        assertFalse(listed);
    }

    function test_controlDelistingBoundPriceDoesNotBreakExistingMandate() public {
        (, bytes32 descriptor) = _bind(address(asset), 3600);
        bytes32 id = _swapMandate();
        registry.delistDescriptor(descriptor);
        assertEq(_swapFire(id), 100e18);
    }

    function test_controlPriceBindingCannotBeChangedByAgentOrEnforcer() public {
        _bind(address(asset), 3600);
        vm.prank(agent);
        vm.expectRevert();
        registry.setPriceRound(address(asset), bytes32(0), address(0));
        vm.prank(enforcer);
        vm.expectRevert();
        registry.setPriceRound(address(asset), bytes32(0), address(0));
    }

    function test_controlChangedRepayConfigCannotReadmitDelistedDebt() public {
        market.setDebt(principal, 500e18);
        market.setCollateral(principal, 1000e18);
        GenericExecutorV1.Config memory c = _repayConfig();
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), c);
        bytes32 id = _register(p);
        registry.delistDescriptor(debtId);
        c.maxSlippageBps = 40;
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "repay:descriptor"));
        core.amendMandate(id, p);
        assertEq(core.getMandate(id).revision, 1);
    }

    function test_controlRepayRejectsAnotherUnderlyingWithEqualDecimals() public {
        MockMarket otherMarket = new MockMarket(IERC20(address(output)));
        GenericExecutorV1.Config memory c = _repayConfig();
        c.market = address(otherMarket);
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "repay:units"));
        core.registerMandate(p);
    }

    function _vaultMandate(MockVault vault, address underlying, uint256 sampleShares, uint256 amount)
        internal
        returns (bytes32)
    {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(0));
        c.sweepSet = new address[](0);
        c.tokenOut = underlying;
        c.signedShares = sampleShares;
        c.signedAssets = vault.convertToAssets(sampleShares);
        c.sanityBandBps = 100;
        c.maxSlippageBps = 50;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = address(vault);
        p.maxTransactionValue = amount;
        p.maxCumulativeValue = amount;
        vm.prank(principal);
        vault.approve(address(core), amount);
        return _register(p);
    }

    function _redeem(bytes32 id, MockVault vault, uint256 pulled, uint256 consumed)
        internal
        returns (uint256)
    {
        IExecutorV1.Call memory call_ = IExecutorV1.Call(
            address(vault),
            address(0),
            address(0),
            0,
            false,
            abi.encodeWithSignature(
                "redeem(uint256,address,address)", consumed, principal, generic.nextClone(id)
            )
        );
        return _fire(id, pulled, _route(call_));
    }

    function _impairedVault() internal returns (MockERC20 usd, FollowupOffsetVault vault) {
        usd = new MockERC20("USD", "USD", 6);
        vault = new FollowupOffsetVault(IERC20(address(usd)));
        uint256 deposit = 1_000_000_000_000e6;
        usd.mint(principal, deposit);
        vm.startPrank(principal);
        usd.approve(address(vault), deposit);
        vault.deposit(deposit, principal);
        vm.stopPrank();
        vm.prank(address(vault));
        usd.transfer(address(0xD00D), deposit - 1_900_000_000_000);
    }

    function test_fixRedeemSampleBandRefusesFortySevenPercentDropAfterSigning() public {
        (MockERC20 usd, FollowupOffsetVault vault) = _impairedVault();
        uint256 shares = 100_000_000_000e18;
        uint256 valueAtSigning = vault.convertToAssets(shares);
        assertEq(valueAtSigning, 190_000e6);
        assertEq(vault.convertToAssets(1e18), 1);
        bytes32 id = _vaultMandate(vault, address(usd), shares, shares);
        // Loss AFTER signing: a 47.36% conversion move must breach the signed 1% band.
        vm.prank(address(vault));
        usd.transfer(address(0xD00D), 900_000_000_000);
        assertEq(vault.convertToAssets(1e18), 1, "unit quote hides the move");
        // The route is built first: its `nextClone` read must not consume the expectRevert.
        bytes memory route = _route(
            IExecutorV1.Call(
                address(vault),
                address(0),
                address(0),
                0,
                false,
                abi.encodeWithSignature(
                    "redeem(uint256,address,address)", shares, principal, generic.nextClone(id)
                )
            )
        );
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 190_000e6, 100_000e6));
        _fire(id, shares, route);
        assertEq(usd.balanceOf(principal), 0);
        assertEq(core.getMandate(id).firings, 0);
    }

    /// The same impaired vault, signed on a one-share sample: the band would span less than
    /// one unit of the underlying, so the contract refuses to admit it.
    function test_fixRedeemSampleTooSmallForTheBandIsRefused() public {
        (MockERC20 usd, FollowupOffsetVault vault) = _impairedVault();
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(0));
        c.sweepSet = new address[](0);
        c.tokenOut = address(usd);
        c.signedShares = 1e18;
        c.signedAssets = vault.convertToAssets(1e18);
        c.sanityBandBps = 100;
        c.maxSlippageBps = 50;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = address(vault);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:precision"));
        core.registerMandate(p);
    }

    function test_controlPartialRedeemUsesPreCallExactAmountQuote() public {
        (MockERC20 usd, FollowupOffsetVault vault) = _impairedVault();
        uint256 pulled = 100_000_000_000e18;
        uint256 consumed = pulled * 4 / 10;
        bytes32 id = _vaultMandate(vault, address(usd), pulled, pulled);
        assertEq(_redeem(id, vault, pulled, consumed), consumed);
        assertEq(usd.balanceOf(principal), 76_000e6);
        assertEq(core.getMandate(id).cumulativeUsed, consumed);
        assertEq(vault.balanceOf(principal), 1_000_000_000_000e18 - consumed);
    }

    function test_controlPartialRedeemRefusesThirtyPercentExitFee() public {
        (MockERC20 usd, FollowupOffsetVault vault) = _impairedVault();
        uint256 pulled = 100_000_000_000e18;
        bytes32 id = _vaultMandate(vault, address(usd), pulled, pulled);
        vault.setExitFee(3000);
        IExecutorV1.Call memory call_ = IExecutorV1.Call(
            address(vault),
            address(0),
            address(0),
            0,
            false,
            abi.encodeWithSignature(
                "redeem(uint256,address,address)", pulled * 4 / 10, principal, generic.nextClone(id)
            )
        );
        vm.expectRevert();
        _fire(id, pulled, _route(call_));
        assertEq(usd.balanceOf(principal), 0);
        assertEq(core.getMandate(id).firings, 0);
    }

    /// The implementation note narrows redemption to a signed conversion band,
    /// not an independent market-price recipe. This is a scope observation only.
    function test_scopeRedeemIntentionallyUsesNoIndependentPriceOracle() public {
        MockVault vault = new MockVault(IERC20(address(asset)));
        vm.startPrank(principal);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, principal);
        vm.stopPrank();
        (MockFeed feed, bytes32 descriptor) = _bind(address(asset), 3600);
        bytes32 id = _vaultMandate(vault, address(asset), 100e18, 100e18);
        feed.set(7, -1, vm.getBlockTimestamp() - 3601, 7);
        vm.prank(enforcer);
        registry.revokeDescriptor(descriptor);
        vm.prank(enforcer);
        registry.suspend(address(feed));
        assertEq(_redeem(id, vault, 100e18, 100e18), 100e18);
        assertEq(core.getMandate(id).firings, 1);
    }
}

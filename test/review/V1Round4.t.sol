// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// An ERC-4626 vault that charges an entry fee in shares: `deposit` mints fewer shares than
/// `convertToShares` quotes. Donations make one share worth a lot, so a one-unit quote truncates.
contract EntryFeeVault is ERC4626 {
    uint256 public entryFeeBps;

    constructor(IERC20 asset_) ERC20("Entry fee vault", "EFV") ERC4626(asset_) {}

    function setEntryFee(uint256 bps) external {
        entryFeeBps = bps;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return super.previewDeposit(assets - assets * entryFeeBps / 10_000);
    }
}

/// Fix round 4 regressions beyond the reviewer's own tests: how the signed price rule behaves
/// on amendment, on a weaker signature and on unpriced actions (C1), and the ERC-4626 deposit
/// minimum, the same unit-quote class as C2 on the other direction.
contract V1Round4Test is V1ReviewBase {
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

    function _swapRoute() internal view returns (bytes memory) {
        return _route(_swap(address(asset), 100e18, principal));
    }

    function _expectConfig(string memory field) internal {
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, field));
    }

    // ------------------------------------------------------------ C1: signed price rule

    /// The owner, not the admin, moves a live mandate to a new rule: an amendment that changes
    /// the config is admitted only with the registry's rule of that moment.
    function test_fixOwnerAmendmentAdoptsTheRegistrysCurrentRule() public {
        (MockFeed feed,) = _bind(address(asset), 3600);
        GenericExecutorV1.Config memory c = _genericConfig();
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), c);
        bytes32 id = _register(p);
        feed.set(8, 1e8, vm.getBlockTimestamp() - 7200, 8);
        bytes32 relaxed = registry.listDescriptor(_round(feed, 86_400));
        registry.setPriceRound(address(asset), relaxed, address(feed));
        bytes memory route = _swapRoute();
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0)
            )
        );
        _fire(id, 100e18, route);
        // Re-signing the old rule with a changed config is refused: admission wants today's rule.
        (, GenericExecutorV1.Config memory signed) =
            abi.decode(p.actionConfig, (uint8, GenericExecutorV1.Config));
        signed.maxSlippageBps = 40;
        p.actionConfig = abi.encode(uint8(1), signed);
        vm.prank(principal);
        _expectConfig("price:round");
        core.amendMandate(id, p);
        // Signing the current rule is admitted, and the owner's new rule now applies.
        c.maxSlippageBps = 40;
        p = _genericParams(generic.ACTION_TRANSFORM(), c);
        vm.prank(principal);
        core.amendMandate(id, p);
        assertEq(core.getMandate(id).revision, 2);
        assertEq(_fire(id, 100e18, route), 100e18);
    }

    /// The owner cannot sign a weaker rule than the registry's: not the no-round mode for a
    /// bound token, and not another listed descriptor with a longer age.
    function test_fixOwnerCannotSignAWeakerRuleThanTheRegistry() public {
        (MockFeed feed,) = _bind(address(asset), 3600);
        bytes32 relaxed = registry.listDescriptor(_round(feed, 86_400));
        GenericExecutorV1.Config memory c = _genericConfig();
        c.prices = _pinned(ExprLib.pair(address(asset), address(output)));
        c.prices[0].descriptor = bytes32(0);
        c.prices[0].feed = address(0);
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), c);
        vm.prank(principal);
        _expectConfig("price:round");
        core.registerMandate(p);
        c.prices[0].descriptor = relaxed;
        c.prices[0].feed = address(feed);
        p = _genericParams(generic.ACTION_TRANSFORM(), c);
        vm.prank(principal);
        _expectConfig("price:round");
        core.registerMandate(p);
        // Rules out of order (or for the wrong tokens) are refused too.
        c.prices = _pinned(ExprLib.pair(address(output), address(asset)));
        p = _genericParams(generic.ACTION_TRANSFORM(), c);
        vm.prank(principal);
        _expectConfig("price:round");
        core.registerMandate(p);
    }

    /// Admin changes pick the rule for NEW mandates only, in both directions: a rule added
    /// after admission does not reach a mandate signed in the explicit no-round mode.
    function test_ruleAddedLaterAppliesToNewMandatesOnly() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        (MockFeed feed,) = _bind(address(asset), 3600);
        feed.set(8, 1e8, vm.getBlockTimestamp() - 7200, 8);
        assertEq(_fire(id, 100e18, _swapRoute()), 100e18, "the signed no-round mode stays in force");
        bytes32 fresh = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        bytes memory route = _swapRoute();
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                fresh,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(IEvaluatorV1.ReadStale.selector, 0)
            )
        );
        _fire(fresh, 100e18, route);
    }

    /// A price rule is signed only where a price is read, so none can be mistaken for a check.
    function test_fixUnpricedActionsRefuseASignedPriceRule() public {
        GenericExecutorV1.Config memory c = _genericConfig();
        c.prices = _pinned(ExprLib.pair(address(asset), address(output)));
        c.rateKind = uint8(GenericExecutorV1.RateKind.Fixed);
        c.rateOrFloor = 1e18;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), c);
        vm.prank(principal);
        _expectConfig("price:round");
        core.registerMandate(p);
        c.recipient = recipient;
        c.venues = new GenericExecutorV1.Venue[](0); // round 8: a transfer signs no venue
        p = _genericParams(generic.ACTION_TRANSFER(), c);
        vm.prank(principal);
        _expectConfig("price:round");
        core.registerMandate(p);
    }

    // ------------------------------------------- same class as C2: ERC-4626 deposit minimum

    function _pricyVault() internal returns (MockERC20 usd, EntryFeeVault vault) {
        usd = new MockERC20("USD", "USD", 6);
        vault = new EntryFeeVault(IERC20(address(usd)));
        usd.mint(address(this), 1e6 + 666_000e6);
        usd.approve(address(vault), 1e6);
        vault.deposit(1e6, address(this));
        // A donation: one whole share is now worth about 666,000 USD, so a one-USD quote is 1.50 shares.
        usd.transfer(address(vault), 666_000e6);
        usd.mint(principal, 100_000e6);
        vm.prank(principal);
        usd.approve(address(core), type(uint256).max);
    }

    function _depositMandate(MockERC20 usd, EntryFeeVault vault) internal returns (bytes32) {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(vault));
        c.sweepSet = new address[](0);
        c.tokenOut = address(vault);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Erc4626);
        c.maxSlippageBps = 50;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), c);
        p.asset = address(usd);
        p.maxTransactionValue = 100_000e6;
        p.maxCumulativeValue = 100_000e6;
        return _register(p);
    }

    function _depositRoute(MockERC20 usd, EntryFeeVault vault) internal view returns (bytes memory) {
        return _route(
            IExecutorV1.Call(
                address(vault),
                address(vault),
                address(usd),
                100_000e6,
                false,
                abi.encodeCall(vault.deposit, (100_000e6, principal))
            )
        );
    }

    /// A 30% entry fee under a 0.5% mandate. The one-USD quote truncates 1.49 shares to 1, so the
    /// old minimum (99,490 shares) let a 105,105-share deposit through; the exact pre-call quote
    /// of the whole amount (150,150 shares, minimum 149,384) refuses it.
    function test_fixVaultDepositMinimumUsesTheExactPreCallQuote() public {
        (MockERC20 usd, EntryFeeVault vault) = _pricyVault();
        assertEq(vault.convertToShares(1e6), 1, "a one-unit quote truncates");
        uint256 quote = vault.convertToShares(100_000e6);
        assertEq(quote, 150_150);
        bytes32 id = _depositMandate(usd, vault);
        vault.setEntryFee(3_000);
        uint256 minted = vault.previewDeposit(100_000e6);
        assertEq(minted, 105_105);
        uint256 exact = quote * 9_950 / 10_000;
        uint256 minOut = exact - (exact / 10_000 + 1);
        bytes memory route = _depositRoute(usd, vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, minted, minOut)
            )
        );
        _fire(id, 100_000e6, route);
        assertEq(usd.balanceOf(principal), 100_000e6);
        assertEq(vault.balanceOf(principal), 0);
    }

    function test_controlVaultDepositWithoutFeePasses() public {
        (MockERC20 usd, EntryFeeVault vault) = _pricyVault();
        bytes32 id = _depositMandate(usd, vault);
        assertEq(_fire(id, 100_000e6, _depositRoute(usd, vault)), 100_000e6);
        assertEq(vault.balanceOf(principal), 150_150);
    }
}

/// Fix round 5 (O1): the one-unit admission filter is replaced by a per-firing precision floor
/// on the exact quote, so an expensive-share vault is admitted but a deposit too small to price
/// within 1% is refused.
contract V1Round5Test is V1ReviewBase {
    function _vault() internal returns (MockERC20 usd, EntryFeeVault vault) {
        usd = new MockERC20("USD", "USD", 6);
        vault = new EntryFeeVault(IERC20(address(usd)));
        usd.mint(address(this), 1e6 + 666_000e6);
        usd.approve(address(vault), 1e6);
        vault.deposit(1e6, address(this));
        usd.transfer(address(vault), 666_000e6); // one USD now quotes 1.50 shares
        usd.mint(principal, 1_000e6);
        vm.prank(principal);
        usd.approve(address(core), type(uint256).max);
    }

    function _mandate(MockERC20 usd, EntryFeeVault vault) internal returns (bytes32) {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(vault));
        c.sweepSet = new address[](0);
        c.tokenOut = address(vault);
        c.rateKind = uint8(GenericExecutorV1.RateKind.Erc4626);
        c.maxSlippageBps = 50;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), c);
        p.asset = address(usd);
        p.maxTransactionValue = 1_000e6;
        p.maxCumulativeValue = 1_000e6;
        return _register(p);
    }

    function _route(MockERC20 usd, EntryFeeVault vault, uint256 amount) internal view returns (bytes memory) {
        return _route(
            IExecutorV1.Call(
                address(vault),
                address(vault),
                address(usd),
                amount,
                false,
                abi.encodeCall(vault.deposit, (amount, principal))
            )
        );
    }

    function test_fixDepositTooSmallToPriceWithinOnePercentIsRefused() public {
        (MockERC20 usd, EntryFeeVault vault) = _vault();
        bytes32 id = _mandate(usd, vault);
        assertEq(vault.convertToShares(50e6), 75, "50 USD quotes 75 shares, under the 100-unit floor");
        bytes memory route = _route(usd, vault, 50e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(GenericExecutorV1.QuoteTooSmall.selector, 75)
            )
        );
        _fire(id, 50e6, route);
        assertEq(vault.balanceOf(principal), 0);
    }

    function test_controlDepositAtTheFloorPasses() public {
        (MockERC20 usd, EntryFeeVault vault) = _vault();
        bytes32 id = _mandate(usd, vault);
        assertEq(vault.convertToShares(100e6), 150);
        assertEq(_fire(id, 100e6, _route(usd, vault, 100e6)), 100e6);
        assertEq(vault.balanceOf(principal), 150);
    }
}

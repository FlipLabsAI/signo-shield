// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

// Review-only dependency: redemption reprices during the call, not before it.
contract ReviewRepricingVault is MockToken {
    address public immutable asset;
    uint256 public rate = 1e18;

    constructor(address underlying) {
        asset = underlying;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }

    function redeem(uint256 shares, address to) external {
        _burn(msg.sender, shares);
        rate = 0.01e18;
        IERC20(asset).transfer(to, shares / 100);
    }
}

contract ReviewBaseUnitMarket {
    IERC20 public immutable asset;
    mapping(address => uint256) public debt;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function setDebt(address who, uint256 amount) external {
        debt[who] = amount;
    }

    // USD base value with 8 decimals for a 6-decimal $1 debt asset.
    function accountData(address who) external view returns (uint256, uint256) {
        return (1_000_000e8, debt[who] * 100);
    }

    function repay(address who, uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        debt[who] -= amount;
    }
}

contract ReviewStickyToken is MockToken {
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) value -= 1;
        super._update(from, to, value);
    }
}

contract ReviewPullLinkedMarket {
    /// @dev The debt figure is in the asset\'s units (18), as the fixed units rule requires.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address who) external view returns (uint256) {
        return debtOf[who];
    }

    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return address(token);
    }

    IERC20 internal token;
    mapping(address => uint256) public debtOf;

    constructor(IERC20 t) {
        token = t;
    }

    function setDebt(address who, uint256 value) external {
        debtOf[who] = value;
    }

    function collateralOf(address who) external view returns (uint256) {
        return token.balanceOf(who);
    }

    function repay(address who, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        debtOf[who] -= amount;
    }
}

contract V1ReviewActionsTest is V1ReviewBase {
    /// F5 (fixed): a revoked mandatory oracle stops the firing.
    function test_fixRevokedMandatoryOracleStopsFiring() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        address clone = generic.nextClone(id);
        vm.prank(enforcer);
        registry.revoke(address(oracle));
        vm.expectRevert();
        _fire(id, 100e18, _route(_swap(address(asset), 100e18, clone)));
        assertEq(output.balanceOf(principal), 0);
    }

    function test_fixRepayCollateralSnapshotIsBeforeCorePull() public {
        ReviewPullLinkedMarket m = new ReviewPullLinkedMarket(IERC20(address(asset)));
        m.setDebt(principal, 1_000e18);
        GenericExecutorV1.Config memory c = _repayConfig();
        c.venues[0] = GenericExecutorV1.Venue(address(m), address(m));
        c.market = address(m);
        c.collateralTarget = address(m);
        bytes32 id = _register(_genericParams(generic.ACTION_REPAY(), c));
        uint256 before = m.collateralOf(principal);
        IExecutorV1.Call memory k = IExecutorV1.Call(
            address(m),
            address(m),
            address(asset),
            100e18,
            false,
            abi.encodeCall(ReviewPullLinkedMarket.repay, (principal, 100e18))
        );
        // F3 (fixed): the collateral snapshot is taken before the pull, so a
        // collateral figure that the pull itself reduces is a fall, and reverts.
        vm.expectRevert();
        _fire(id, 100e18, _route(k));
        assertEq(m.collateralOf(principal), before);
        assertEq(m.debtOf(principal), 1_000e18);
    }

    function test_controlTransformSweepsPrefundedAssetWithoutReducingCharge() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        address clone = generic.nextClone(id);
        asset.mint(clone, 1_000e18);
        assertEq(_fire(id, 100e18, _route(_swap(address(asset), 100e18, clone))), 100e18);
        assertEq(asset.balanceOf(clone), 0);
        assertEq(core.getMandate(id).cumulativeUsed, 100e18);
    }

    function test_controlBlockedConcreteSpenderAndTargetRefuseFiring() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        bytes memory route = _route(_swap(address(asset), 100e18, generic.nextClone(id)));
        vm.prank(enforcer);
        registry.suspend(address(dex));
        vm.expectRevert();
        _fire(id, 100e18, route);
        vm.prank(enforcer);
        registry.revoke(address(dex));
        vm.expectRevert();
        _fire(id, 100e18, route);
    }

    /// F1 (closed, claim round 23 Sep): claim-and-reinvest is not an action any more, and a
    /// collect firing takes no calls from the agent, so there is no claim to label or relabel.
    function test_fixComposeIsNotAnActionAndCollectTakesNoAgentCalls() public {
        IShieldV1.MandateParams memory p = _claimParams(_claimConfig());
        p.action = keccak256("claim.compose");
        vm.prank(principal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.ActionNotSupported.selector, address(claims), keccak256("claim.compose")
            )
        );
        core.registerMandate(p);
        distributor.setOwed(principal, 100e18);
        bytes32 id = _register(_claimParams(_claimConfig()));
        bytes memory route = _route(_claim(principal, recipient, true));
        vm.expectRevert();
        _fire(id, 0, route);
        assertEq(distributor.claimable(principal), 100e18);
        assertEq(reward.balanceOf(recipient), 0);
    }

    /// F2 (closed, claim round 23 Sep): the claim call is built from the listed rule with the
    /// owner in both of its account arguments, so the owner's 100 reach the owner and nobody
    /// else's claim is touched; the claimable amount read first is met.
    function test_fixCollectIsBoundToTheOwnerAndMeetsTheClaimableFloor() public {
        distributor.setOwed(principal, 100e18);
        distributor.setOwed(recipient, 1e18);
        bytes32 id = _register(_claimParams(_claimConfig()));
        _fire(id, 0, "");
        assertEq(reward.balanceOf(principal), 100e18);
        assertEq(reward.balanceOf(recipient), 0);
        assertEq(distributor.claimable(principal), 0);
        assertEq(distributor.claimable(recipient), 1e18);
    }

    function test_controlClaimApprovalRejectedEvenWithTrueOutcome() public {
        distributor.setOwed(principal, 100e18);
        bytes32 id = _register(_claimParams(_claimConfig()));
        IExecutorV1.Call memory k = _claim(principal, claims.nextClone(id), true);
        k.spender = address(distributor);
        k.approveToken = address(reward);
        k.approveAmount = 100e18;
        vm.expectRevert();
        _fire(id, 0, _route(k));
        assertEq(distributor.claimable(principal), 100e18);
    }

    /// F4 (fixed): the minimum is priced at the pre-call conversion and the
    /// sanity band holds after the call too, so a vault that reprices inside
    /// the redemption cannot lower its own promise.
    function test_fixRedeemIsPricedBeforeTheCall() public {
        ReviewRepricingVault vault = new ReviewRepricingVault(address(asset));
        vault.mint(principal, 100e18);
        asset.mint(address(vault), 100e18);
        vm.prank(principal);
        vault.approve(address(core), 100e18);
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(vault), address(0));
        c.sweepSet = new address[](0);
        c.tokenOut = address(asset);
        c.signedShares = 100e18;
        c.signedAssets = 100e18; // the repricing vault converts 1:1 until it redeems
        c.sanityBandBps = 100;
        c.maxSlippageBps = 50;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = address(vault);
        bytes32 id = _register(p);
        uint256 before = asset.balanceOf(principal);
        IExecutorV1.Call memory k = IExecutorV1.Call(
            address(vault),
            address(0),
            address(0),
            0,
            false,
            abi.encodeCall(ReviewRepricingVault.redeem, (100e18, principal))
        );
        vm.expectRevert();
        _fire(id, 100e18, _route(k));
        assertEq(asset.balanceOf(principal), before);
        assertEq(vault.balanceOf(principal), 100e18);
    }

    /// F3 (fixed): a debt read in base-currency units is refused at registration.
    function test_fixRepayRefusesBaseCurrencyUnits() public {
        MockERC20 usd = new MockERC20("USD", "USD", 6);
        ReviewBaseUnitMarket m = new ReviewBaseUnitMarket(IERC20(address(usd)));
        usd.mint(principal, 1_000e6);
        vm.prank(principal);
        usd.approve(address(core), 1_000e6);
        m.setDebt(principal, 1_000e6);
        IDescriptors.Descriptor memory d = _descriptor(ReviewBaseUnitMarket.accountData.selector);
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(m);
        d.copyBytes = 64;
        d.decimals = 8;
        bytes32 col = registry.listDescriptor(d);
        d.word = 1;
        bytes32 debt = registry.listDescriptor(d);
        GenericExecutorV1.Config memory c = _repayConfig();
        c.venues = new GenericExecutorV1.Venue[](2);
        c.venues[0] = GenericExecutorV1.Venue(address(m), address(m));
        c.venues[1] = GenericExecutorV1.Venue(address(dex), address(dex));
        c.tokenOut = address(usd);
        c.market = address(m);
        c.collateralTarget = address(m);
        c.debtDescriptor = debt;
        c.collateralDescriptor = col;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), c);
        p.asset = address(usd);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "repay:units"));
        core.registerMandate(p);
    }

    /// F3 (fixed): a per-address debt descriptor must be bound to the signed market.
    function test_fixRepayBindsPerAddressDescriptorTarget() public {
        IDescriptors.Descriptor memory d = _descriptor(bytes4(keccak256("debtOf(address)")));
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(market);
        bytes32 perAddressDebt = registry.listDescriptor(d);
        MockMarket other = new MockMarket(IERC20(address(asset)));
        other.setDebt(principal, 100e18);
        other.setCollateral(principal, 200e18);
        GenericExecutorV1.Config memory c = _repayConfig();
        c.venues[0] = GenericExecutorV1.Venue(address(other), address(other));
        c.market = address(other);
        c.collateralTarget = address(other);
        c.debtDescriptor = perAddressDebt;
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_REPAY(), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "repay:debt"));
        core.registerMandate(p);
    }

    function test_controlTransformTrueTreeDoesNotRemoveSlippageFloor() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        dex.setSkim(100);
        bytes memory route = _route(_swap(address(asset), 100e18, generic.nextClone(id)));
        vm.expectRevert();
        _fire(id, 100e18, route);
        assertEq(core.getMandate(id).cumulativeUsed, 0);
        assertEq(generic.firings(id), 0);
    }

    function test_controlRepayTrueTreeDoesNotRemoveCollateralCheck() public {
        market.setDebt(principal, 500e18);
        market.setCollateral(principal, 1_000e18);
        bytes32 id = _register(_genericParams(generic.ACTION_REPAY(), _repayConfig()));
        market.setSteal(true);
        vm.expectRevert();
        _fire(id, 100e18, _route(_repayCall(100e18)));
        assertEq(market.collateralOf(principal), 1_000e18);
    }

    function test_controlTransferMeasuresExactRecipientBalance() public {
        GenericExecutorV1.Config memory c = _genericConfig();
        c.recipient = recipient;
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFER(), c));
        _fire(id, 100e18, "");
        assertEq(asset.balanceOf(recipient), 100e18);
        assertEq(core.getMandate(id).cumulativeUsed, 100e18);
    }

    function test_controlExactPairsAndApprovalTokenAndOneUseSandbox() public {
        GenericExecutorV1.Config memory c = _genericConfig();
        c.venues = new GenericExecutorV1.Venue[](2);
        c.venues[0] = GenericExecutorV1.Venue(address(dex), address(dex));
        c.venues[1] = GenericExecutorV1.Venue(address(distributor), address(distributor));
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), c));
        address clone = generic.nextClone(id);
        IExecutorV1.Call memory k = _swap(address(asset), 100e18, clone);
        k.spender = address(distributor);
        vm.expectRevert();
        _fire(id, 100e18, _route(k));
        k.spender = address(dex);
        k.approveToken = address(reward);
        vm.expectRevert();
        _fire(id, 100e18, _route(k));
        k.approveToken = address(asset);
        _fire(id, 100e18, _route(k));
        assertEq(asset.allowance(clone, address(dex)), 0);
        assertEq(asset.balanceOf(clone), 0);
        assertEq(output.balanceOf(clone), 0);
        vm.expectRevert(DisposableCloneV1.NotExecutor.selector);
        DisposableCloneV1(clone).step(k);
        vm.prank(address(generic));
        vm.expectRevert(DisposableCloneV1.AlreadyUsed.selector);
        DisposableCloneV1(clone).step(k);
        IExecutorV1.Context memory ctx;
        vm.expectRevert(GenericExecutorV1.NotShield.selector);
        generic.execute(ctx, 0, "");
        vm.expectRevert(ClaimExecutorV1.NotShield.selector);
        claims.execute(ctx, 0, "");
    }

    /// F8 (fixed): the sandbox is proven empty after the sweep, or the firing reverts.
    function test_fixGenericRevertsWhenASweptTokenSticks() public {
        ReviewStickyToken sticky = new ReviewStickyToken();
        GenericExecutorV1.Config memory c = _genericConfig();
        c.sweepSet = new address[](1);
        c.sweepSet[0] = address(sticky);
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), c));
        address clone = generic.nextClone(id);
        sticky.mint(clone, 100);
        vm.expectRevert();
        _fire(id, 100e18, _route(_swap(address(asset), 100e18, clone)));
        assertEq(sticky.balanceOf(principal), 0);
    }

    /// F12 (fixed): a per-call approval above what the sandbox holds is refused.
    function test_fixUnlimitedSandboxApprovalIsRefused() public {
        bytes32 id = _register(_genericParams(generic.ACTION_TRANSFORM(), _genericConfig()));
        address clone = generic.nextClone(id);
        IExecutorV1.Call memory k = _swap(address(asset), 100e18, clone);
        k.approveAmount = type(uint256).max;
        vm.expectRevert();
        _fire(id, 100e18, _route(k));
        assertEq(asset.allowance(clone, address(dex)), 0);
    }
}

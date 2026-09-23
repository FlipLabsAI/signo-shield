// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Review-only venue models an externally moveable conversion and an in-call reprice.
/// This is an admission-boundary fixture, not evidence that a listed live vault behaves this way.
contract R7QuotedVault is MockToken {
    address public immutable asset;
    uint256 public rate;
    uint256 public nextRate;
    uint256 public payBps = 10_000;

    constructor(address underlying, uint256 rate_) {
        asset = underlying;
        rate = rate_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function configure(uint256 r, uint256 bps) external {
        nextRate = r;
        payBps = bps;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, rate, 1e18);
    }

    function redeem(uint256 shares, address to) external {
        uint256 quote = convertToAssets(shares);
        _burn(msg.sender, shares);
        if (nextRate != 0) rate = nextRate;
        IERC20(asset).transfer(to, Math.mulDiv(quote, payBps, 10_000));
    }
}

contract V1Round7RedeemTest is V1ReviewBase {
    function _vault(uint256 rate) internal returns (R7QuotedVault v) {
        v = new R7QuotedVault(address(asset), rate);
        v.mint(principal, 10e18);
        asset.mint(address(v), 1_000_000e18);
        vm.prank(principal);
        v.approve(address(core), type(uint256).max);
    }

    function _paramsFor(R7QuotedVault v, bool floor)
        internal
        view
        returns (IShieldV1.MandateParams memory p)
    {
        GenericExecutorV1.Config memory c;
        c.venues = new GenericExecutorV1.Venue[](1);
        c.venues[0] = GenericExecutorV1.Venue(address(v), address(0));
        c.tokenOut = address(asset);
        c.maxSlippageBps = 50;
        if (floor) {
            c.signedShares = 1e18;
            c.signedAssets = v.convertToAssets(1e18);
            c.sanityBandBps = 100;
        }
        p = _genericParams(generic.ACTION_REDEEM(), c);
        p.asset = address(v);
    }

    function _routeFor(R7QuotedVault v, uint256 shares, address to) internal pure returns (bytes memory) {
        return _route(
            IExecutorV1.Call(
                address(v),
                address(0),
                address(0),
                0,
                false,
                abi.encodeCall(R7QuotedVault.redeem, (shares, to))
            )
        );
    }

    function _reject(bytes32 id, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector, id, IShieldV1.MandateReason.OUTCOME_FAILED, reason
            )
        );
    }

    function test_boundaryNoFloorCanRedeemFormerlyValuableSharesForOneRawUnit() public {
        R7QuotedVault v = _vault(1e18);
        bytes32 id = _register(_paramsFor(v, false));
        // Models a low quote before snapshot, not a pre-call/post-call quote substitution.
        v.setRate(1);
        uint256 before_ = asset.balanceOf(principal);
        assertEq(_fire(id, 1e18, _routeFor(v, 1e18, principal)), 1e18);
        assertEq(asset.balanceOf(principal) - before_, 1);
        assertEq(core.getMandate(id).cumulativeUsed, 1e18);
    }

    function test_floorStopsTheSameLowQuoteBeforePull() public {
        R7QuotedVault v = _vault(1e18);
        bytes32 id = _register(_paramsFor(v, true));
        v.setRate(1);
        bytes memory route = _routeFor(v, 1e18, principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 1e18, 1));
        _fire(id, 1e18, route);
        assertEq(v.balanceOf(principal), 10e18);
        assertEq(generic.nextClone(id).code.length, 0);
        assertEq(core.getMandate(id).firings, 0);
    }

    function test_lowerFloorRecheckedAfterCallWithInwardRoundingAndRollback() public {
        R7QuotedVault v = _vault(10_001);
        bytes32 id = _register(_paramsFor(v, true));
        address clone = generic.nextClone(id);
        v.configure(9900, 10_000);
        bytes memory route = _routeFor(v, 0.1e18, principal);
        _reject(id, abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 10_001, 9900));
        _fire(id, 0.1e18, route);
        assertEq(v.rate(), 10_001);
        assertEq(v.balanceOf(principal), 10e18);
        assertEq(clone.code.length, 0);
        assertEq(core.getMandate(id).firings, 0);
        v.configure(9901, 10_000);
        assertEq(_fire(id, 0.1e18, route), 0.1e18);
        assertEq(v.rate(), 9901);
    }

    function test_noFloorStillRejectsUnderpaymentAgainstExactPreCallQuote() public {
        R7QuotedVault v = _vault(1e18);
        bytes32 id = _register(_paramsFor(v, false));
        v.configure(1, 7000);
        bytes memory route = _routeFor(v, 1e18, principal);
        vm.expectRevert();
        _fire(id, 1e18, route);
        assertEq(v.rate(), 1e18);
        assertEq(v.balanceOf(principal), 10e18);
        assertEq(core.getMandate(id).firings, 0);
    }

    function test_noFloorStillRequiresOwnerReceiptAndChargesOnlyConsumedShares() public {
        R7QuotedVault v = _vault(1e18);
        bytes32 id = _register(_paramsFor(v, false));
        bytes memory redirected = _routeFor(v, 0.5e18, recipient);
        vm.expectRevert();
        _fire(id, 1e18, redirected);
        uint256 before_ = asset.balanceOf(principal);
        assertEq(_fire(id, 1e18, _routeFor(v, 0.5e18, principal)), 0.5e18);
        assertEq(v.balanceOf(principal), 9.5e18);
        assertEq(asset.balanceOf(principal) - before_, 0.5e18);
        assertEq(core.getMandate(id).cumulativeUsed, 0.5e18);
    }

    function test_growthBeforeAndDuringFiringNeverTripsOptionalFloor() public {
        R7QuotedVault v = _vault(1e18);
        bytes32 id = _register(_paramsFor(v, true));
        v.setRate(2e18);
        v.configure(3e18, 10_000);
        uint256 before_ = asset.balanceOf(principal);
        assertEq(_fire(id, 1e18, _routeFor(v, 1e18, principal)), 1e18);
        assertEq(asset.balanceOf(principal) - before_, 2e18);
        assertEq(v.rate(), 3e18);
    }

    function test_signingChecksBothEdgesButOnlyToTheSignedTolerance() public {
        R7QuotedVault v = _vault(10_001);
        IShieldV1.MandateParams memory p = _paramsFor(v, true);
        (, GenericExecutorV1.Config memory c) = abi.decode(p.actionConfig, (uint8, GenericExecutorV1.Config));
        c.signedAssets = 10_103; // lower bound ceil(10103*0.99) = 10002
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 10_103, 10_001));
        core.registerMandate(p);
        c.signedAssets = 10_000;
        v.setRate(10_101); // upper bound floor(10000*1.01) = 10100
        p.actionConfig = abi.encode(uint8(1), c);
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.SanityBand.selector, 10_000, 10_101));
        core.registerMandate(p);
        v.setRate(10_100);
        assertEq(core.getMandate(_register(p)).revision, 1);
    }

    function test_noFloorRejectsEitherSampleFieldAndDecorativeOracle() public {
        R7QuotedVault v = _vault(1e18);
        IShieldV1.MandateParams memory p = _paramsFor(v, false);
        (, GenericExecutorV1.Config memory c) = abi.decode(p.actionConfig, (uint8, GenericExecutorV1.Config));
        c.signedShares = 1;
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:sanity"));
        generic.validateConfig(keccak256("generic.redeem"), address(v), abi.encode(uint8(1), c));
        c.signedShares = 0;
        c.signedAssets = 1;
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:sanity"));
        generic.validateConfig(keccak256("generic.redeem"), address(v), abi.encode(uint8(1), c));
        c.signedAssets = 0;
        c.oracle = address(oracle);
        vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "redeem:oracle"));
        generic.validateConfig(keccak256("generic.redeem"), address(v), abi.encode(uint8(1), c));
    }
}

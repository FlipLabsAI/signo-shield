// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {ClaimExecutorV1} from "contracts/v1/ClaimExecutorV1.sol";

interface IClaimsPendleMarket {
    function userReward(address token, address user) external view returns (uint128, uint128);
    function redeemRewards(address user) external returns (uint256[] memory);
    function getRewardTokens() external view returns (address[] memory);
    function readTokens() external view returns (address, address, address);
}

contract V1ClaimsPendleConfirmationTest is Test {
    uint256 internal constant ORIGINAL_BLOCK = 70_752_723;
    // Public RPC latest block sampled on 23 Sep 2026; sources/pendle-live-evidence.json preserves hash/time/code.
    uint256 internal constant CURRENT_SAMPLE = 71_385_014;
    address internal constant MARKET = 0xcFB506cb34DD340e80d3dF8764182a5187636032;
    address internal constant PENDLE = 0x5E49E1f85813F2B65858860A3FA231b4186f2e0E;
    address internal constant HOLDER = 0xe28239FD8d6D71e3B289eDBFd9DD19b62B25B658;
    address internal constant AGENT = address(0xA6E);
    address internal constant STRANGER = address(0xBEEF);
    bytes32 internal constant CODE_HASH = 0xb4663dec2f81bffe44b8cc24f01312e2c3477a4fa1f0ea4fa7b952277e300b84;

    function _fork(uint256 n) internal {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), n);
        assertEq(MARKET.codehash, CODE_HASH);
        address[] memory tokens = IClaimsPendleMarket(MARKET).getRewardTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], PENDLE);
        (address sy,,) = IClaimsPendleMarket(MARKET).readTokens();
        assertEq(IClaimsPendleMarket(sy).getRewardTokens().length, 0, "no external SY reward token");
    }

    function _direct(uint256 n) internal {
        _fork(n);
        (, uint128 accrued) = IClaimsPendleMarket(MARKET).userReward(PENDLE, HOLDER);
        assertGt(accrued, 0);
        uint256 ownerBefore = IERC20(PENDLE).balanceOf(HOLDER);
        uint256 callerBefore = IERC20(PENDLE).balanceOf(STRANGER);
        uint256 lpBefore = IERC20(MARKET).balanceOf(HOLDER);
        vm.prank(STRANGER);
        uint256[] memory returned = IClaimsPendleMarket(MARKET).redeemRewards(HOLDER);
        uint256 got = IERC20(PENDLE).balanceOf(HOLDER) - ownerBefore;
        assertEq(returned.length, 1);
        assertEq(returned[0], got);
        assertGe(got, accrued);
        assertEq(IERC20(PENDLE).balanceOf(STRANGER), callerBefore);
        assertEq(IERC20(MARKET).balanceOf(HOLDER), lpBefore);
        (, uint128 left) = IClaimsPendleMarket(MARKET).userReward(PENDLE, HOLDER);
        assertEq(left, 0);
        console2.log("block", n);
        console2.log("stored accrued", uint256(accrued));
        console2.log("owner received", got);
    }

    function _deployMandate() internal returns (DeployV1.Deployed memory d, bytes32 id) {
        DeployV1 script_ = new DeployV1();
        d = script_.deployWith(address(this), address(0), address(0xE0), 0);
        d.registry.acceptOwnership();
        ClaimExecutorV1.Config memory c;
        c.claims = new bytes32[](1);
        c.claims[0] = keccak256(abi.encode(script_.pendleRedeemRewards(MARKET)));
        c.rewardTokens = new address[](1);
        c.rewardTokens[0] = PENDLE;
        c.claimable = new ExprLib.Read[](1);
        c.claimable[0] = ExprLib.Read(
            d.registry.descriptorId(script_.pendleAccrued(MARKET)),
            MARKET,
            abi.encode(PENDLE, address(0)),
            ExprLib.Subject.Principal,
            18
        );
        IShieldV1.MandateParams memory p;
        p.agent = AGENT;
        p.executor = address(d.claims);
        p.evaluator = address(d.evaluator);
        p.asset = PENDLE;
        p.funding = uint8(IShieldV1.FundingMode.NONE);
        p.action = d.claims.ACTION_CLAIM_COLLECT();
        p.actionConfig = abi.encode(uint8(1), c);
        p.validFrom = uint48(block.timestamp);
        p.validUntil = uint48(block.timestamp + 30 days);
        vm.prank(HOLDER);
        id = d.shield.registerMandate(p);
    }

    function test_pinnedPermissionlessClaimPaysNamedHolderNotCaller() public {
        _direct(ORIGINAL_BLOCK);
    }

    function test_todayPermissionlessClaimPaysNamedHolderNotCaller() public {
        _direct(CURRENT_SAMPLE);
    }

    function test_todayStockDeploymentClaimPaysFullAccruedEvenWithNoLpRemaining() public {
        _fork(CURRENT_SAMPLE);
        (DeployV1.Deployed memory d, bytes32 id) = _deployMandate();
        assertEq(IERC20(MARKET).balanceOf(HOLDER), 0);
        (, uint128 accrued) = IClaimsPendleMarket(MARKET).userReward(PENDLE, HOLDER);
        uint256 before_ = IERC20(PENDLE).balanceOf(HOLDER);
        address clone = d.claims.nextClone(id);
        vm.prank(AGENT);
        assertEq(d.shield.fire(id, 0, ""), 0);
        assertGe(IERC20(PENDLE).balanceOf(HOLDER) - before_, accrued);
        assertEq(IERC20(PENDLE).balanceOf(clone), 0);
        assertEq(IERC20(PENDLE).allowance(clone, MARKET), 0);
        assertEq(d.shield.getMandate(id).cumulativeUsed, 0);
        vm.prank(AGENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, PENDLE)
            )
        );
        d.shield.fire(id, 0, "");
        assertEq(d.shield.getMandate(id).firings, 1);
    }

    function test_pinnedZeroStoredAccruedCanStillCollectNewRewardsAfterTimePasses() public {
        _fork(ORIGINAL_BLOCK);
        (DeployV1.Deployed memory d, bytes32 id) = _deployMandate();
        vm.prank(AGENT);
        d.shield.fire(id, 0, "");
        // Local fork time progression only: the getter is storage, not a current accrued estimate.
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        (, uint128 accrued) = IClaimsPendleMarket(MARKET).userReward(PENDLE, HOLDER);
        assertEq(accrued, 0);
        uint256 before_ = IERC20(PENDLE).balanceOf(HOLDER);
        vm.prank(AGENT);
        d.shield.fire(id, 0, "");
        uint256 got = IERC20(PENDLE).balanceOf(HOLDER) - before_;
        assertGt(got, 0);
        console2.log("zero stored accrued, newly claimed after simulated day", got);
    }
}

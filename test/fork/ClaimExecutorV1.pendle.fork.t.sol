// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployV1} from "script/DeployV1.s.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {ClaimExecutorV1} from "contracts/v1/ClaimExecutorV1.sol";

interface IPendleMarketRewards {
    function userReward(address token, address user) external view returns (uint128 index, uint128 accrued);
}

/// A real PENDLE claim through the stock deployment on X Layer: the Pendle USDG market's
/// reward claim, run by the claims executor from the listed rule, for a real LP holder.
contract ClaimExecutorV1PendleForkTest is Test {
    /// An LP holder of the USDG market with accrued PENDLE at the pinned block (found from the
    /// market's LP transfer logs; 3.3e9 LP, 0.013 PENDLE accrued).
    address internal constant HOLDER = 0xe28239FD8d6D71e3B289eDBFd9DD19b62B25B658;
    DeployV1 internal script;
    DeployV1.Deployed internal d;
    address internal market;
    address internal pendle;
    address internal agent = address(0xA6E);
    address internal enforcer = address(0xE0);

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), 70_752_723);
        script = new DeployV1();
        d = script.deployWith(address(this), address(0), enforcer, 0);
        d.registry.acceptOwnership();
        market = script.PENDLE_USDG_MARKET();
        pendle = script.PENDLE_XLAYER();
    }

    function _mandate() internal returns (bytes32 id) {
        ClaimExecutorV1.Config memory c;
        c.claims = new bytes32[](1);
        c.claims[0] = keccak256(abi.encode(script.pendleRedeemRewards(market)));
        c.rewardTokens = new address[](1);
        c.rewardTokens[0] = pendle;
        c.claimable = new ExprLib.Read[](1);
        c.claimable[0] = ExprLib.Read(
            d.registry.descriptorId(script.pendleAccrued(market)),
            market,
            abi.encode(pendle, address(0)),
            ExprLib.Subject.Principal,
            18
        );
        IShieldV1.MandateParams memory p = IShieldV1.MandateParams({
            agent: agent,
            executor: address(d.claims),
            evaluator: address(d.evaluator),
            asset: pendle,
            maxTransactionValue: 0,
            maxCumulativeValue: 0,
            validFrom: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 30 days),
            maxFeeBps: 0,
            funding: uint8(IShieldV1.FundingMode.NONE),
            action: d.claims.ACTION_CLAIM_COLLECT(),
            actionConfig: abi.encode(uint8(1), c),
            trigger: "",
            outcome: ""
        });
        vm.prank(HOLDER);
        id = d.shield.registerMandate(p);
    }

    function test_stockDeploymentListsTheClaimsExecutorAndThePendleRule() public view {
        assertTrue(d.registry.isExecutorListed(address(d.claims)));
        (IShieldRegistryV1.ClaimRule memory r, bool listed, bool revoked) =
            d.registry.claimRuleOf(keccak256(abi.encode(script.pendleRedeemRewards(market))));
        assertTrue(listed);
        assertFalse(revoked);
        assertEq(r.target, market);
        assertEq(r.selector, bytes4(keccak256("redeemRewards(address)")));
        assertEq(r.ownerArgs, 1);
    }

    function test_realPendleClaimPaysTheOwnerAtLeastTheAccruedAmount() public {
        (, uint128 accrued) = IPendleMarketRewards(market).userReward(pendle, HOLDER);
        assertGt(accrued, 0, "fixture: the holder has accrued PENDLE at the pinned block");
        bytes32 id = _mandate();
        uint256 before = IERC20(pendle).balanceOf(HOLDER);
        vm.prank(agent);
        assertEq(d.shield.fire(id, 0, ""), 0);
        uint256 got = IERC20(pendle).balanceOf(HOLDER) - before;
        console.log("accrued before", uint256(accrued));
        console.log("claimed       ", got);
        assertGe(got, accrued);
        (, uint128 left) = IPendleMarketRewards(market).userReward(pendle, HOLDER);
        assertEq(left, 0);
        // Immediately again: nothing is owed, so nothing is claimed and the firing reverts.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(ClaimExecutorV1.NothingClaimed.selector, pendle)
            )
        );
        d.shield.fire(id, 0, "");
    }

    function test_anEnforcerRevokingTheRuleStopsTheLiveMandate() public {
        bytes32 id = _mandate();
        bytes32 ruleId = keccak256(abi.encode(script.pendleRedeemRewards(market)));
        vm.prank(enforcer);
        d.registry.revokeClaimRule(ruleId);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(ClaimExecutorV1.ClaimRuleRevoked.selector, ruleId)
            )
        );
        d.shield.fire(id, 0, "");
    }
}

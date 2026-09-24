// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {R1112GenericFixture} from "./R1112GenericFixture.sol";
import {R12SharedLedger, R12AliasToken} from "./V1Round1112Outputs.t.sol";
import {MockToken, MockFeeToken} from "test/v1/mocks/MockExecutor.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Honest share accounting, but the exchange index can change during a route.
contract R14RebasingOutput {
    mapping(address => uint256) public shares;
    uint256 public index = 1;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address who) external view returns (uint256) {
        return shares[who] * index;
    }

    function mint(address who, uint256 value) external {
        shares[who] += value / index;
    }

    function rebase() external {
        index = 2;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        shares[msg.sender] -= value / index;
        shares[to] += value / index;
        return true;
    }
}

contract R14RebaseVenue {
    function swap(address input, R14RebasingOutput output, uint256 amount, address receiver) external {
        IERC20(input).transferFrom(msg.sender, address(this), amount);
        output.mint(receiver, amount);
        output.rebase();
    }
}

contract V1Round14IsolationTest is R1112GenericFixture {
    function _unpriced(address out) internal view returns (GenericExecutorV1.Config memory c) {
        c = _cfg();
        c.tokenOut = out;
        c.rateKind = uint8(GenericExecutorV1.RateKind.Unpriced);
        c.oracle = address(0);
        c.maxSlippageBps = 0;
    }

    function _rebaseCase(bool several) internal {
        R14RebasingOutput out = new R14RebasingOutput();
        R14RebaseVenue venue = new R14RebaseVenue();
        out.mint(principal, 1); // Existing holding: no receipt from this route.
        GenericExecutorV1.Config memory c = _unpriced(address(out));
        c.venues[0] = GenericExecutorV1.Venue(address(venue), address(venue));
        if (several) {
            c.moreOuts = new GenericExecutorV1.Output[](1);
            c.moreOuts[0] = GenericExecutorV1.Output(address(weth), 0);
        }
        bytes32 id = _register(c);
        address clone = exec.nextClone(id);
        IExecutorV1.Call memory k = IExecutorV1.Call({
            target: address(venue),
            spender: address(venue),
            approveToken: address(usdc),
            approveAmount: 100e18,
            claimStep: false,
            data: abi.encodeCall(R14RebaseVenue.swap, (address(usdc), out, 100e18, agent))
        });
        vm.prank(agent);
        shield.fire(id, 100e18, _route(k));
        assertEq(out.shares(principal), 1, "owner received no shares from the route");
        assertEq(out.balanceOf(principal), 2, "passive index increase passes receipt check");
        assertEq(out.shares(agent), 100e18, "actual bought output was paid elsewhere");
        assertEq(out.balanceOf(clone), 0);
        assertEq(shield.getMandate(id).cumulativeUsed, 100e18);
    }

    function test_r14_rebaseIsNotProofOfReceiptSingle() public {
        _rebaseCase(false);
    }

    function test_r14_rebaseIsNotProofOfReceiptSeveral() public {
        _rebaseCase(true);
    }

    function test_r14_feeOnTransferChecksNetOwnerReceipt() public {
        MockFeeToken out = new MockFeeToken();
        bytes32 id = _register(_unpriced(address(out)));
        address clone = exec.nextClone(id);
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapTo(address(out), 100e18, clone)));
        assertEq(out.balanceOf(principal), 99e18);
        assertEq(out.balanceOf(address(0xFEE)), 1e18, "tax is not swept to owner");
        assertEq(out.balanceOf(clone), 0);
    }

    function test_r14_independentOutputRoutedElsewhereRollsBack() public {
        bytes32 id = _register(_unpriced(address(weth)));
        uint256 initial = usdc.balanceOf(principal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, 0, 1)
            )
        );
        vm.prank(agent);
        shield.fire(id, 100e18, _route(_swapTo(address(weth), 100e18, agent)));
        assertEq(weth.balanceOf(agent), 0);
        assertEq(usdc.balanceOf(principal), initial);
        assertEq(shield.getMandate(id).firings, 0);
    }

    function test_r14_aliasesDoNotMultiplyOneUnitRequirement() public {
        R12SharedLedger ledger = new R12SharedLedger();
        R12AliasToken a = new R12AliasToken(ledger);
        R12AliasToken b = new R12AliasToken(ledger);
        GenericExecutorV1.Config memory c = _unpriced(address(a));
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output(address(b), 0);
        bytes32 id = _register(c);
        dex.setRate(1);
        address clone = exec.nextClone(id);
        vm.prank(agent);
        shield.fire(id, 1e18, _route(_swapTo(address(a), 1e18, clone)));
        assertEq(ledger.balance(principal), 1, "exactly one real unit settles as intended");
        assertEq(ledger.balance(clone), 0);
    }

    function test_r14_outputCannotAlsoBeVenueOrSpender() public {
        GenericExecutorV1.Config memory c = _unpriced(address(weth));
        c.venues[0].target = address(weth);
        _refused(
            c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "venue:target")
        );
        c = _unpriced(address(weth));
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output(address(mid), 0);
        c.venues[0].spender = address(mid);
        _refused(
            c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "venue:spender")
        );
    }

    function test_r14_floorCannotReachZeroFloorFallback() public {
        MockToken second = _wbtc();
        GenericExecutorV1.Config memory c = _anyCfg(second, true);
        c.rateOrFloor = 0;
        _refused(c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "floor"));
        c = _anyCfg(second, true);
        c.moreOuts[0].floor = 0;
        _refused(c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "moreOuts"));
    }

    function test_r14_unpricedStillRejectsUnsignedVenue() public {
        bytes32 id = _register(_unpriced(address(weth)));
        IExecutorV1.Call memory k = _swapTo(address(weth), 100e18, exec.nextClone(id));
        k.target = address(market);
        vm.expectRevert();
        vm.prank(agent);
        shield.fire(id, 100e18, _route(k));
        assertEq(shield.getMandate(id).firings, 0);
    }
}

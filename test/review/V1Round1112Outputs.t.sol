// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {R1112GenericFixture} from "./R1112GenericFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockToken} from "test/v1/mocks/MockExecutor.sol";
import {MockOracle} from "test/v1/mocks/MockVenues.sol";

/// Explicit adversarial oracle dependency: a route can change its quote.
/// This is NOT Aave's deployed oracle and proves no permissionless Aave exploit.
contract R12MovingPriceVenue {
    function swap(address input, address output, address oracle, uint256 amount, address to) external {
        IERC20(input).transferFrom(msg.sender, address(this), amount);
        MockToken(output).mint(to, amount / 100);
        MockOracle(oracle).set(output, 100e8);
    }
}

/// Two token addresses representing one ledger, not two independently owned balances.
contract R12SharedLedger {
    mapping(address => uint256) public balance;

    function mint(address to, uint256 amount) external {
        balance[to] += amount;
    }

    function move(address from, address to, uint256 amount) external {
        balance[from] -= amount;
        balance[to] += amount;
    }
}

contract R12AliasToken {
    R12SharedLedger public immutable ledger;

    constructor(R12SharedLedger l) {
        ledger = l;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address who) external view returns (uint256) {
        return ledger.balance(who);
    }

    function mint(address to, uint256 amount) external {
        ledger.mint(to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        ledger.move(msg.sender, to, amount);
        return true;
    }
}

contract V1Round1112OutputsTest is R1112GenericFixture {
    function _movingPriceCase(bool several) internal {
        GenericExecutorV1.Config memory c = several ? _anyCfg(_wbtc(), false) : _cfg();
        R12MovingPriceVenue venue = new R12MovingPriceVenue();
        c.venues[0] = GenericExecutorV1.Venue(address(venue), address(venue));
        bytes32 id = _register(c);
        IExecutorV1.Call memory k = IExecutorV1.Call({
            target: address(venue),
            spender: address(venue),
            approveToken: address(usdc),
            approveAmount: 100e18,
            claimStep: false,
            data: abi.encodeCall(
                R12MovingPriceVenue.swap,
                (address(usdc), address(weth), address(oracle), 100e18, exec.nextClone(id))
            )
        });
        uint256 before = usdc.balanceOf(principal);
        // Round 13 fix of G12-H1: one valuation, read before the route, for one
        // output or several. 1 weth at its pre-route $1 is 1e26 against 9.95e27
        // needed (100 USDC less 0.5%), whatever the route did to the oracle.
        vm.expectRevert(
            abi.encodeWithSelector(
                IShieldV1.OutcomeRejected.selector,
                id,
                IShieldV1.MandateReason.OUTCOME_FAILED,
                abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, 1e26, 995e25)
            )
        );
        vm.prank(agent);
        shield.fire(id, 100e18, _route(k));
        assertEq(usdc.balanceOf(principal), before);
        assertEq(weth.balanceOf(principal), 0);
        assertEq(oracle.getAssetPrice(address(weth)), 1e8, "rollback");
    }

    function test_r13_fixSeveralOutputsJudgeOnPreRoutePrices() public {
        _movingPriceCase(true);
    }

    function test_r12_singleOutputKeepsPreRouteQuoteAndRejectsSameLoss() public {
        _movingPriceCase(false);
    }

    function _aliasCase(bool floors) internal {
        R12SharedLedger ledger = new R12SharedLedger();
        R12AliasToken first = new R12AliasToken(ledger);
        R12AliasToken second = new R12AliasToken(ledger);
        oracle.set(address(first), 1e8);
        oracle.set(address(second), 1e8);
        GenericExecutorV1.Config memory c = _cfg();
        c.tokenOut = address(first);
        c.moreOuts = new GenericExecutorV1.Output[](1);
        c.moreOuts[0] = GenericExecutorV1.Output(address(second), floors ? 100e18 : 0);
        if (floors) {
            c.rateKind = uint8(GenericExecutorV1.RateKind.Floor);
            c.rateOrFloor = 100e18;
            c.oracle = address(0);
            c.maxSlippageBps = 0;
        } else {
            c.prices = new ExprLib.PriceRound[](3);
            c.prices[0] = ExprLib.PriceRound(address(usdc), bytes32(0), address(0));
            c.prices[1] = ExprLib.PriceRound(address(first), bytes32(0), address(0));
            c.prices[2] = ExprLib.PriceRound(address(second), bytes32(0), address(0));
        }
        // Round 13 fix of G12-H2: the several outputs must be tokens the
        // registry bound a round for, so two aliases over one ledger are refused
        // at registration unless the admin reviewed and listed both.
        _refused(c, TRANSFORM, abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "moreOuts"));
    }

    function test_r13_fixAliasesAreRefusedAtTheOracle() public {
        _aliasCase(false);
    }

    function test_r13_fixAliasesAreRefusedWithFloors() public {
        _aliasCase(true);
    }

    function test_r12_duplicateSweepDoesNotDuplicateIndependentValue() public {
        MockToken wbtc = _wbtc();
        GenericExecutorV1.Config memory c = _anyCfg(wbtc, false);
        c.sweepSet = new address[](2);
        c.sweepSet[0] = address(weth);
        c.sweepSet[1] = address(wbtc);
        bytes32 id = _register(c);
        dex.setRate(0.25e18); // $50 output against $100 input
        uint256 before = usdc.balanceOf(principal);
        bytes memory route = _route(_swapTo(address(wbtc), 100e18, exec.nextClone(id)));
        vm.prank(agent);
        vm.expectRevert();
        shield.fire(id, 100e18, route);
        assertEq(usdc.balanceOf(principal), before);
        assertEq(wbtc.balanceOf(principal), 0);
    }

    function testFuzz_r12_floorSharesRoundConservatively(uint256 seed) public {
        MockToken wbtc = _wbtc();
        GenericExecutorV1.Config memory c = _anyCfg(wbtc, true);
        bytes32 id = _register(c);
        uint256 first = bound(uint256(seed), 1, 99e18);
        uint256 second = (100e18 - first) * 40 / 100;
        // Both mints use the same 1:1 test route: spend first+second.
        address clone = exec.nextClone(id);
        bytes memory route =
            _route2(_swapTo(address(weth), first, clone), _swapTo(address(wbtc), second, clone));
        uint256 score = first * 1e18 / 100e18 + second * 1e18 / 40e18;
        if (score < 1e18) vm.expectRevert();
        vm.prank(agent);
        shield.fire(id, first + second, route);
        if (score >= 1e18) {
            assertGe(weth.balanceOf(principal) * 40 + wbtc.balanceOf(principal) * 100, 4000e18);
        }
    }
}

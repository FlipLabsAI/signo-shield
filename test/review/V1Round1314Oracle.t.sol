// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {R1112GenericFixture} from "./R1112GenericFixture.sol";
import {R13PreFixGeneric} from "./R13PreFixGeneric.sol";
import {MockToken} from "test/v1/mocks/MockExecutor.sol";
import {PinnedPrices} from "test/v1/mocks/PinnedPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenericExecutorV1} from "contracts/v1/GenericExecutorV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {IShieldRegistryV1} from "contracts/v1/interfaces/IShieldRegistryV1.sol";
import {IExecutorV1} from "contracts/v1/interfaces/IExecutorV1.sol";

contract R13DecimalToken is MockToken {
    uint8 private immutable precision;

    constructor(uint8 d) {
        precision = d;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }
}

/// Explicit route prices with ordinary transfers; no mutable oracle/balance trick.
contract R13ExactVenue {
    function swap(address input, address output, uint256 amount, uint256 pay, address to) external {
        IERC20(input).transferFrom(msg.sender, address(this), amount);
        MockToken(output).mint(to, pay);
    }
}

contract V1Round1314OracleTest is R1112GenericFixture {
    function _inputCase(uint8 dec, uint256 price, uint256 amount, uint256 pay, bool several, bool old)
        internal
    {
        if (old) {
            exec = GenericExecutorV1(address(new R13PreFixGeneric(address(shield))));
            vm.prank(admin);
            registry.setExecutor(address(exec), true);
        }
        R13DecimalToken input = new R13DecimalToken(dec);
        input.mint(principal, amount);
        oracle.set(address(input), price);
        R13ExactVenue venue = new R13ExactVenue();
        GenericExecutorV1.Config memory c = _cfg();
        c.venues[0] = GenericExecutorV1.Venue(address(venue), address(venue));
        if (several) {
            _review(address(weth));
            _review(address(mid));
            oracle.set(address(mid), 1e8);
            c.moreOuts = new GenericExecutorV1.Output[](1);
            c.moreOuts[0] = GenericExecutorV1.Output(address(mid), 0);
            address[] memory tokens = new address[](3);
            tokens[0] = address(input);
            tokens[1] = address(weth);
            tokens[2] = address(mid);
            c.prices = PinnedPrices.pin(IShieldRegistryV1(address(registry)), tokens);
        }
        IShieldV1.MandateParams memory p = _params(TRANSFORM, address(input), c, 0);
        p.maxTransactionValue = amount;
        p.maxCumulativeValue = amount;
        vm.startPrank(principal);
        input.approve(address(shield), amount);
        if (!old) {
            // Round 15 (G13-H1 fix): a token over 18 decimals cannot be valued
            // exactly at the oracle and is refused at admission.
            vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "oracle"));
            shield.registerMandate(p);
            vm.stopPrank();
            return;
        }
        bytes32 id = shield.registerMandate(p);
        vm.stopPrank();
        bytes memory route = _route(
            IExecutorV1.Call({
                target: address(venue),
                spender: address(venue),
                approveToken: address(input),
                approveAmount: amount,
                claimStep: false,
                data: abi.encodeCall(
                    R13ExactVenue.swap, (address(input), address(weth), amount, pay, exec.nextClone(id))
                )
            })
        );
        uint256 exactFloor = amount * price * 1e18 / (10 ** dec * 1e8) * 995 / 1000;
        assertLt(pay, exactFloor, "route really violates the owner's 0.5% bound");
        if (old) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IShieldV1.OutcomeRejected.selector,
                    id,
                    IShieldV1.MandateReason.OUTCOME_FAILED,
                    abi.encodeWithSelector(GenericExecutorV1.OutputBelowMinimum.selector, pay, exactFloor)
                )
            );
        }
        vm.prank(agent);
        shield.fire(id, amount, route);
        assertEq(input.balanceOf(principal), old ? amount : 0);
        assertEq(weth.balanceOf(principal), old ? 0 : pay);
        assertEq(shield.getMandate(id).cumulativeUsed, old ? 0 : amount);
    }

    function test_r15_fix19DecimalInputIsRefusedAtAdmission() public {
        // 10 billion tokens at $0.00000019 = $1,900. Receives $995.
        _inputCase(19, 19, 1e29, 995e18, false, false);
    }

    function test_r15_fix26DecimalInputIsRefusedAtAdmission() public {
        // 100 tokens at $1.99999999; per-unit value truncates from 1.99999999 to 1.
        _inputCase(26, 199_999_999, 1e28, 995e17, false, false);
    }

    function test_r15_fix27DecimalInputIsRefusedAtAdmission() public {
        _inputCase(27, 1e8, 100e27, 1, false, false);
    }

    function test_r15_fixMultiOutputOver18DecimalsIsRefused() public {
        _inputCase(26, 199_999_999, 1e28, 995e17, true, false);
    }

    function test_r12ControlRejectsSame19DecimalLoss() public {
        _inputCase(19, 19, 1e29, 995e18, false, true);
    }

    function test_r12ControlRejectsSame26DecimalLoss() public {
        _inputCase(26, 199_999_999, 1e28, 995e17, false, true);
    }

    function test_r12ControlRejectsSameZeroUnitInputLoss() public {
        _inputCase(27, 1e8, 100e27, 1, false, true);
    }

    function _outputCase(bool old) internal {
        if (old) {
            exec = GenericExecutorV1(address(new R13PreFixGeneric(address(shield))));
            vm.prank(admin);
            registry.setExecutor(address(exec), true);
        }
        R13DecimalToken out = new R13DecimalToken(27);
        oracle.set(address(out), 1e8);
        R13ExactVenue venue = new R13ExactVenue();
        GenericExecutorV1.Config memory c = _cfg();
        c.tokenOut = address(out);
        c.venues[0] = GenericExecutorV1.Venue(address(venue), address(venue));
        if (!old) {
            vm.expectRevert(abi.encodeWithSelector(GenericExecutorV1.ConfigInvalid.selector, "oracle"));
            vm.prank(principal);
            shield.registerMandate(_params(TRANSFORM, address(usdc), c, 0));
            return;
        }
        bytes32 id = _register(c);
        bytes memory route = _route(
            IExecutorV1.Call({
                target: address(venue),
                spender: address(venue),
                approveToken: address(usdc),
                approveAmount: 100e18,
                claimStep: false,
                data: abi.encodeCall(
                    R13ExactVenue.swap, (address(usdc), address(out), 100e18, 100e27, exec.nextClone(id))
                )
            })
        );
        vm.prank(agent);
        shield.fire(id, 100e18, route);
        assertEq(out.balanceOf(principal), old ? 100e27 : 0);
        assertEq(shield.getMandate(id).firings, old ? 1 : 0);
    }

    function test_r15_fix27DecimalOutputIsRefusedAtAdmission() public {
        _outputCase(false);
    }

    function test_r12ControlAllowsSameFair27DecimalOutput() public {
        _outputCase(true);
    }
}

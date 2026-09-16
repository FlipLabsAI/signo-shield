// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {GenericExecutor} from "contracts/executors/GenericExecutor.sol";
import {IShieldAdapter} from "contracts/core/interfaces/IShieldAdapter.sol";

/// The fourth rule against a real vault: Sky's sDAI on Ethereum mainnet, the
/// most-used ERC-4626 there is. No protocol Solidity in the path; the
/// executor learns which vault it is from the mandate and nothing else.
/// Run: MAINNET_RPC_URL=… forge test --match-path test/fork/GenericExecutor4626.fork.t.sol -vv
contract GenericExecutor4626ForkTest is Test {
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    uint256 internal constant AMOUNT = 1_000e18;

    GenericExecutor internal executor;
    address internal principal = makeAddr("principal");
    bytes32 internal constant MANDATE = keccak256("mandate-sdai");

    function setUp() public {
        // Latest, not a pinned block: the public endpoint is not an archive
        // node and refuses state more than a few hundred blocks back. The
        // block is logged so a run is still on the record; nothing asserted
        // depends on which block it was.
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        console.log("fork block:", block.number);
        executor = new GenericExecutor(address(this));
    }

    function test_sdaiDeposit_throughTheExecutor_realVault() public {
        // The registration-time checks, against the real contract.
        assertEq(IERC4626(SDAI).asset(), DAI, "sDAI is a vault over DAI");
        bytes memory cfg = abi.encode(
            GenericExecutor.TransformConfig({
                tokenOut: SDAI, target: SDAI, spender: SDAI,
                rateKind: GenericExecutor.RateKind.Erc4626, oracle: address(0), rateOrFloor: 0, maxSlippageBps: 0
            })
        );
        executor.validateConfig(keccak256("generic.transform"), DAI, cfg);

        uint256 perUnit = IERC4626(SDAI).convertToShares(1e18);
        assertGt(perUnit, 0, "sDAI prices a whole DAI");
        assertLt(perUnit, 1e18, "sDAI has earned: a DAI buys less than one share");
        uint256 preview = IERC4626(SDAI).previewDeposit(AMOUNT);

        deal(DAI, address(executor), AMOUNT);
        address clone = executor.nextClone(MANDATE);
        IShieldAdapter.Context memory ctx = IShieldAdapter.Context({
            mandateId: MANDATE, principal: principal, agent: address(0xA6E47),
            action: keccak256("generic.transform"), asset: DAI, actionConfig: cfg
        });
        uint256 gasBefore = gasleft();
        uint256 spent = executor.execute(ctx, AMOUNT, abi.encodeCall(IERC4626.deposit, (AMOUNT, principal)));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(spent, AMOUNT, "the whole slice went in");
        uint256 got = IERC20(SDAI).balanceOf(principal);
        assertGe(got, preview, "at least what the vault previewed");
        assertGe(got, AMOUNT * perUnit / 1e18 - (AMOUNT * perUnit / 1e18 / 10_000 + 1), "and at least the bound");
        assertEq(IERC20(DAI).balanceOf(clone), 0, "sandbox holds nothing");
        assertEq(IERC20(SDAI).balanceOf(clone), 0);
        assertEq(IERC20(DAI).allowance(clone, SDAI), 0, "no approval survives");
        assertEq(IERC20(DAI).balanceOf(address(executor)), 0, "executor holds nothing");
        console.log("gas, sDAI deposit through the generic executor:", gasUsed);
        console.log("shares per DAI (1e18):", perUnit);
    }
}

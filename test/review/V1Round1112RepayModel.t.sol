// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {ShieldV1} from "contracts/v1/ShieldV1.sol";
import {ShieldRegistryV1} from "contracts/v1/ShieldRegistryV1.sol";
import {ExpressionEvaluator} from "contracts/v1/ExpressionEvaluator.sol";
import {AaveV3AdapterV1} from "contracts/v1/AaveV3AdapterV1.sol";
import {IShieldV1} from "contracts/v1/interfaces/IShieldV1.sol";
import {ExprLib} from "contracts/v1/libraries/ExprLib.sol";
import {MockToken} from "test/v1/mocks/MockExecutor.sol";
import {MockAaveOracle, MockDataProvider, MockAddressesProvider} from "test/mocks/MockAave.sol";
import {MockRouter} from "test/mocks/MockRouter.sol";
import {R1112LegacyAave} from "./R1112LegacyAave.sol";

contract R1112BurnableToken is MockToken {
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// Honest arithmetic model, not deployed Aave. Fixed 95% liquidation threshold,
/// $1 prices, no interest, no external position mutation: HF = collateral*LT/debt.
/// The owner remains above 1 even immediately after the pull. No oracle trick.
contract R1112RatioPool {
    address public immutable ADDRESSES_PROVIDER;
    R1112BurnableToken public immutable receipt;
    R1112BurnableToken public immutable debt;
    MockToken public immutable collateral;
    MockToken public immutable debtAsset;

    constructor(address provider, R1112BurnableToken a, R1112BurnableToken d, MockToken col, MockToken cash) {
        ADDRESSES_PROVIDER = provider;
        receipt = a;
        debt = d;
        collateral = col;
        debtAsset = cash;
    }

    function getUserAccountData(address who)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        uint256 c = receipt.balanceOf(who);
        uint256 d = debt.balanceOf(who);
        return (c / 1e10, d / 1e10, 0, 9_500, 9_300, d == 0 ? type(uint256).max : c * 95 * 1e18 / (100 * d));
    }

    function supply(address asset, uint256 amount, address who, uint16) external {
        require(asset == address(collateral));
        collateral.transferFrom(msg.sender, address(this), amount);
        receipt.mint(who, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(collateral));
        if (amount == type(uint256).max) amount = receipt.balanceOf(msg.sender);
        receipt.burn(msg.sender, amount);
        collateral.transfer(to, amount);
        return amount;
    }

    function repay(address asset, uint256 amount, uint256, address who) external returns (uint256) {
        require(asset == address(debtAsset));
        debtAsset.transferFrom(msg.sender, address(this), amount);
        debt.burn(who, amount);
        return amount;
    }
}

contract V1Round1112RepayModelTest is Test {
    address internal owner = address(0xA11CE);
    address internal agent = address(0xA6E);
    MockToken internal col;
    MockToken internal cash;
    R1112BurnableToken internal a;
    R1112BurnableToken internal d;
    R1112RatioPool internal pool;
    ShieldV1 internal shield;
    ExpressionEvaluator internal ev;
    AaveV3AdapterV1 internal adapter;
    MockRouter internal router;

    function _setup(bool legacy) internal {
        col = new MockToken();
        cash = new MockToken();
        a = new R1112BurnableToken();
        d = new R1112BurnableToken();
        MockAaveOracle oracle = new MockAaveOracle();
        oracle.set(address(col), 1e8);
        oracle.set(address(cash), 1e8);
        MockDataProvider data = new MockDataProvider();
        data.set(address(col), address(a), address(0));
        data.set(address(cash), address(0), address(d));
        MockAddressesProvider provider = new MockAddressesProvider(address(oracle), address(data));
        pool = new R1112RatioPool(address(provider), a, d, col, cash);
        ShieldRegistryV1 registry = new ShieldRegistryV1(address(this));
        shield = new ShieldV1(registry, 0);
        ev = new ExpressionEvaluator(registry);
        adapter = legacy
            ? AaveV3AdapterV1(address(new R1112LegacyAave(address(shield), IPool(address(pool)))))
            : new AaveV3AdapterV1(address(shield), IPool(address(pool)));
        router = new MockRouter();
        registry.setExecutor(address(adapter), true);
        registry.setEvaluator(address(ev), true);
        a.mint(owner, 100e18);
        col.mint(address(pool), 100e18);
        d.mint(owner, uint256(95e18) * 1e18 / 1.05e18);
        cash.mint(address(router), 100e18);
    }

    function _exercise(bool legacy) internal {
        _setup(legacy);
        ExprLib.PriceRound[] memory prices = new ExprLib.PriceRound[](2);
        prices[0] = ExprLib.PriceRound(address(col), bytes32(0), address(0));
        prices[1] = ExprLib.PriceRound(address(cash), bytes32(0), address(0));
        IShieldV1.MandateParams memory p;
        p.agent = agent;
        p.executor = address(adapter);
        p.evaluator = address(ev);
        p.action = keccak256("aave-v3.repayWithCollateral");
        p.asset = address(a);
        p.maxTransactionValue = 2e18;
        p.maxCumulativeValue = 20e18;
        p.validUntil = uint48(block.timestamp + 1 days);
        p.actionConfig = abi.encode(
            uint8(1),
            AaveV3AdapterV1.RepayWithCollateralConfig({
                collateral: address(col),
                debtAsset: address(cash),
                targetHealthFactor: 1.8e18,
                maxSlippageBps: 1_000,
                slippageOverride: true,
                router: address(router),
                spender: address(router),
                prices: prices
            })
        );
        vm.startPrank(owner);
        a.approve(address(shield), type(uint256).max);
        bytes32 id = shield.registerMandate(p);
        vm.stopPrank();
        (,,,,, uint256 hfBefore) = pool.getUserAccountData(owner);
        uint256 afterPull = 99e18 * 95 * 1e18 / (100 * d.balanceOf(owner));
        assertGt(afterPull, 1e18, "pull remains solvent without relying on a missing mock guard");
        bytes memory route =
            abi.encodeCall(MockRouter.swap, (address(col), 1e18, address(cash), 0.9e18, address(adapter)));
        // Round 13 fix of G11-H1: the step beats the post-pull position but not
        // the pre-firing one, so the current adapter refuses it by name, as the
        // old target rule refused it.
        if (legacy) {
            vm.expectRevert();
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IShieldV1.OutcomeRejected.selector,
                    id,
                    IShieldV1.MandateReason.OUTCOME_FAILED,
                    abi.encodeWithSelector(
                        AaveV3AdapterV1.OutcomeFailed.selector, "health factor did not rise"
                    )
                )
            );
        }
        vm.prank(agent);
        shield.fire(id, 1e18, route);
        (,,,,, uint256 hfAfter) = pool.getUserAccountData(owner);
        assertEq(hfAfter, hfBefore, "a worsening step is refused and rolled back");
        assertEq(a.balanceOf(owner), 100e18);
        assertEq(shield.getMandate(id).firings, 0);
    }

    function test_r13_fixAStepThatLowersThePreFiringHealthFactorIsRefused() public {
        _exercise(false);
    }

    function test_r1112_oldTargetRuleRejectsWorseningStep() public {
        _exercise(true);
    }
}

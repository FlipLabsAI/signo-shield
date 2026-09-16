// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3Adapter} from "contracts/adapters/aave-v3/AaveV3Adapter.sol";
import {IPool} from "contracts/adapters/aave-v3/interfaces/IAaveV3.sol";
import {MockAaveOracle, MockAddressesProvider, MockDataProvider, MockPool} from "./mocks/MockAave.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Exposes the adapter's minimum-output arithmetic.
contract AdapterHarness is AaveV3Adapter {
    constructor(address shield_, IPool pool_) AaveV3Adapter(shield_, pool_) {}

    function minOut(RepayWithCollateralConfig memory c, uint256 collateralAmount)
        external
        view
        returns (uint256)
    {
        return _minOut(c, collateralAmount);
    }
}

/// The slippage bound must be right whatever the two tokens' decimals are:
/// the real markets only ever exercise 18 -> 6.
contract AaveV3AdapterMinOutTest is Test {
    MockAaveOracle internal oracle;
    AdapterHarness internal adapter;
    address internal router = address(new MockERC20("r", "r", 18)); // any contract with code

    function setUp() public {
        oracle = new MockAaveOracle();
        MockDataProvider dp = new MockDataProvider();
        MockAddressesProvider provider = new MockAddressesProvider(address(oracle), address(dp));
        MockPool pool = new MockPool(address(provider));
        adapter = new AdapterHarness(address(this), IPool(address(pool)));
    }

    function _cfg(address collateral, address debt, uint16 slippageBps)
        internal
        view
        returns (AaveV3Adapter.RepayWithCollateralConfig memory)
    {
        return AaveV3Adapter.RepayWithCollateralConfig({
            collateral: collateral,
            debtAsset: debt,
            targetHealthFactor: 1e18,
            maxSlippageBps: slippageBps,
            router: router,
            spender: router
        });
    }

    function test_18to6() public {
        MockERC20 col = new MockERC20("xETH", "xETH", 18);
        MockERC20 debt = new MockERC20("USDT0", "USDT0", 6);
        oracle.set(address(col), 2_400e8);
        oracle.set(address(debt), 1e8);
        // 0.01 xETH at 2,400 = 24 USDT0, less 1% = 23.76
        assertEq(adapter.minOut(_cfg(address(col), address(debt), 100), 0.01e18), 23.76e6);
    }

    function test_8to6() public {
        MockERC20 col = new MockERC20("xBTC", "xBTC", 8);
        MockERC20 debt = new MockERC20("USDT0", "USDT0", 6);
        oracle.set(address(col), 76_000e8);
        oracle.set(address(debt), 1e8);
        // 0.001 xBTC at 76,000 = 76 USDT0, less 50 bps = 75.62
        assertEq(adapter.minOut(_cfg(address(col), address(debt), 50), 0.001e8), 75.62e6);
    }

    function test_6to18() public {
        MockERC20 col = new MockERC20("USDT0", "USDT0", 6);
        MockERC20 debt = new MockERC20("xETH", "xETH", 18);
        oracle.set(address(col), 1e8);
        oracle.set(address(debt), 2_400e8);
        // 240 USDT0 at 2,400 per xETH = 0.1 xETH, less 1% = 0.099
        assertEq(adapter.minOut(_cfg(address(col), address(debt), 100), 240e6), 0.099e18);
    }

    function test_zeroPriceIsRefused() public {
        MockERC20 col = new MockERC20("x", "x", 18);
        MockERC20 debt = new MockERC20("y", "y", 6);
        oracle.set(address(col), 0);
        oracle.set(address(debt), 1e8);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.OutcomeFailed.selector, "oracle price"));
        adapter.minOut(_cfg(address(col), address(debt), 100), 1e18);
    }

    /// The bound scales linearly with the amount and never exceeds parity.
    function testFuzz_boundIsLinearAndBelowParity(
        uint8 colDec,
        uint8 debtDec,
        uint64 colPrice,
        uint64 debtPrice,
        uint96 amount,
        uint16 bps
    ) public {
        colDec = uint8(bound(colDec, 0, 24));
        debtDec = uint8(bound(debtDec, 0, 24));
        colPrice = uint64(bound(colPrice, 1e6, 1e14)); // 0.01 to 1e6 USD at 8 decimals
        debtPrice = uint64(bound(debtPrice, 1e6, 1e14));
        bps = uint16(bound(bps, 1, 1_000));
        MockERC20 col = new MockERC20("c", "c", colDec);
        MockERC20 debt = new MockERC20("d", "d", debtDec);
        oracle.set(address(col), colPrice);
        oracle.set(address(debt), debtPrice);
        AaveV3Adapter.RepayWithCollateralConfig memory c = _cfg(address(col), address(debt), bps);

        uint256 parity =
            (uint256(amount) * colPrice * (10 ** debtDec)) / (uint256(debtPrice) * (10 ** colDec));
        uint256 bound_ = adapter.minOut(c, amount);
        assertLe(bound_, parity, "never above parity");
        assertGe(bound_ + 1, (parity * (10_000 - bps)) / 10_000, "haircut, up to rounding");
        assertLe(adapter.minOut(c, amount / 2) * 2, bound_ + 2, "linear, up to rounding");
    }
}

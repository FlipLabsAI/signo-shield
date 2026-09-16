// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal Aave V3 surfaces the adapter needs. Signatures match aave-v3-origin
/// (`IPool`, `IPoolAddressesProvider`, `IPoolDataProvider`, `IAaveOracle`);
/// only the functions used here are declared so the adapter compiles against
/// nothing but its own code.

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function getPriceOracle() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}

interface IPoolDataProvider {
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}

interface IAaveOracle {
    /// @notice Price of `asset` in the market's base currency (USD, 8 decimals on every Aave V3 market).
    function getAssetPrice(address asset) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Just enough Aave surface for the adapter's pure arithmetic to be tested
/// with arbitrary token decimals and oracle prices.
contract MockAaveOracle {
    mapping(address => uint256) public prices;

    function set(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
}

contract MockDataProvider {
    struct Tokens {
        address aToken;
        address variableDebt;
    }

    mapping(address => Tokens) public tokens;

    function set(address asset, address aToken, address variableDebt) external {
        tokens[asset] = Tokens(aToken, variableDebt);
    }

    function getReserveTokensAddresses(address asset) external view returns (address, address, address) {
        Tokens memory t = tokens[asset];
        return (t.aToken, address(0), t.variableDebt);
    }
}

contract MockAddressesProvider {
    address public oracle;
    address public dataProvider;

    constructor(address oracle_, address dataProvider_) {
        oracle = oracle_;
        dataProvider = dataProvider_;
    }

    function getPriceOracle() external view returns (address) {
        return oracle;
    }

    function getPoolDataProvider() external view returns (address) {
        return dataProvider;
    }
}

contract MockPool {
    address public immutable provider;

    constructor(address provider_) {
        provider = provider_;
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return provider;
    }
}

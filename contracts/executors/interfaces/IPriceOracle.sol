// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPriceOracle
/// @notice The one read the generic executor makes for an oracle-rated
///         mandate: a price per whole token in a common base unit. Aave's
///         `IAaveOracle` has this exact shape (base currency with 8 decimals
///         on X Layer); another feed is wrapped into it by a small contract,
///         never by trusting an agent-supplied quote.
interface IPriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

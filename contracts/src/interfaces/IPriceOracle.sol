// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice Interface for the PriceOracle contract that maintains historical price data
interface IPriceOracle {

    /// @notice Updates prices for multiple assets in a single transaction
    /// @param assets Array of asset symbols to update prices for
    /// @param newPrices Array of new prices corresponding to each asset
    /// @custom:reverts If caller is not the owner
    /// @custom:reverts If assets and prices arrays have different lengths
    /// @custom:reverts If any price is zero or negative
    function updatePrices(
        string[] memory assets,
        uint256[] memory newPrices
    ) external;

    /// @notice Retrieves the most recent price for a given asset
    /// @param asset The symbol of the asset to get the price for
    /// @return The latest price for the specified asset
    /// @custom:reverts If no price data exists for the asset
    function getLatestPrice(
        string memory asset
    ) external view returns (uint256);
} 
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title PriceOracle
/// @notice A contract that maintains historical price data for various assets
/// @dev Stores price history in arrays and provides latest price retrieval functionality
contract PriceOracle is IPriceOracle {
    /// @notice The address that has permission to update prices
    address public owner;

    /// @notice Maps asset symbols to their historical price arrays
    /// @dev Each asset's price history is stored as an array of prices in chronological order
    mapping(string => uint256[]) public priceHistory;

    /// @notice Emitted when a new price is updated for an asset
    /// @param asset The symbol of the asset whose price was updated
    /// @param newPrice The new price value that was set
    event PriceUpdated(string indexed asset, uint256 newPrice);

    /// @notice Initializes the contract and sets the deployer as the owner
    constructor() {
        owner = msg.sender;
    }

    /// @notice Updates prices for multiple assets in a single transaction
    /// @dev Only callable by the owner. Validates input arrays and price values
    /// @param assets Array of asset symbols to update prices for
    /// @param newPrices Array of new prices corresponding to each asset
    /// @custom:reverts If caller is not the owner
    /// @custom:reverts If assets and prices arrays have different lengths
    /// @custom:reverts If any price is zero or negative
    function updatePrices(
        string[] memory assets,
        uint256[] memory newPrices
    ) external override {
        if (msg.sender != owner) {
            revert("Only owner can update prices");
        }

        if (assets.length != newPrices.length) {
            revert("Assets and prices array length mismatch");
        }

        for (uint256 i = 0; i < assets.length; i++) {
            if (newPrices[i] <= 0) {
                revert("Price must be greater than 0");
            }
            priceHistory[assets[i]].push(newPrices[i]); // Store each new price in the array for the asset
            emit PriceUpdated(assets[i], newPrices[i]);
        }
    }

    /// @notice Retrieves the most recent price for a given asset
    /// @dev Returns the last element in the asset's price history array
    /// @param asset The symbol of the asset to get the price for
    /// @return The latest price for the specified asset
    /// @custom:reverts If no price data exists for the asset
    function getLatestPrice(
        string memory asset
    ) external view override returns (uint256) {
        uint256 length = priceHistory[asset].length;
        if (length == 0) {
            revert("No price data available");
        }
        return priceHistory[asset][length - 1]; // Get the last price
    }
}

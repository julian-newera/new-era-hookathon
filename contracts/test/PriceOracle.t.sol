// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

/// @title PriceOracleTest
/// @notice Test suite for the PriceOracle contract
/// @dev Tests all major functionality including price updates, access control, and price retrieval
contract PriceOracleTest is Test {
    /// @notice The PriceOracle contract instance being tested
    PriceOracle public priceOracle;
    
    /// @notice The owner address with permission to update prices
    address public owner;
    
    /// @notice A regular user address without special permissions
    address public user;

    /// @notice Sets up the test environment before each test
    /// @dev Deploys a new PriceOracle contract and initializes test addresses
    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        vm.startPrank(owner);
        priceOracle = new PriceOracle();
        vm.stopPrank();
    }

    /// @notice Tests that the constructor correctly sets the owner
    function test_Constructor() public view {
        assertEq(priceOracle.owner(), owner);
    }

    /// @notice Tests successful price updates for multiple assets
    /// @dev Verifies that prices are correctly stored and can be retrieved
    function test_UpdatePrices_Success() public {
        string[] memory assets = new string[](2);
        assets[0] = "BTC";
        assets[1] = "ETH";

        uint256[] memory prices = new uint256[](2);
        prices[0] = 50000;
        prices[1] = 3000;

        vm.startPrank(owner);
        priceOracle.updatePrices(assets, prices);
        vm.stopPrank();

        assertEq(priceOracle.getLatestPrice("BTC"), 50000);
        assertEq(priceOracle.getLatestPrice("ETH"), 3000);
    }

    /// @notice Tests that only the owner can update prices
    /// @dev Verifies that non-owner addresses cannot update prices
    function test_UpdatePrices_OnlyOwner() public {
        string[] memory assets = new string[](1);
        assets[0] = "BTC";

        uint256[] memory prices = new uint256[](1);
        prices[0] = 50000;

        vm.startPrank(user);
        vm.expectRevert("Only owner can update prices");
        priceOracle.updatePrices(assets, prices);
        vm.stopPrank();
    }

    /// @notice Tests that price updates fail when asset and price arrays have different lengths
    /// @dev Verifies input validation for array length matching
    function test_UpdatePrices_ArrayLengthMismatch() public {
        string[] memory assets = new string[](2);
        assets[0] = "BTC";
        assets[1] = "ETH";

        uint256[] memory prices = new uint256[](1);
        prices[0] = 50000;

        vm.startPrank(owner);
        vm.expectRevert("Assets and prices array length mismatch");
        priceOracle.updatePrices(assets, prices);
        vm.stopPrank();
    }

    /// @notice Tests that price updates fail when a zero price is provided
    /// @dev Verifies input validation for price values
    function test_UpdatePrices_ZeroPrice() public {
        string[] memory assets = new string[](1);
        assets[0] = "BTC";

        uint256[] memory prices = new uint256[](1);
        prices[0] = 0;

        vm.startPrank(owner);
        vm.expectRevert("Price must be greater than 0");
        priceOracle.updatePrices(assets, prices);
        vm.stopPrank();
    }

    /// @notice Tests successful retrieval of the latest price
    /// @dev Verifies that getLatestPrice returns the most recently set price
    function test_GetLatestPrice() public {
        string[] memory assets = new string[](1);
        assets[0] = "BTC";

        uint256[] memory prices = new uint256[](1);
        prices[0] = 50000;

        vm.startPrank(owner);
        priceOracle.updatePrices(assets, prices);
        vm.stopPrank();

        assertEq(priceOracle.getLatestPrice("BTC"), 50000);
    }

    /// @notice Tests that price retrieval fails when no price data exists
    /// @dev Verifies error handling for missing price data
    function test_GetLatestPrice_NoData() public {
        vm.expectRevert("No price data available");
        priceOracle.getLatestPrice("BTC");
    }

    /// @notice Tests that price history is correctly maintained across multiple updates
    /// @dev Verifies that the latest price reflects the most recent update
    function test_PriceHistory_Updates() public {
        string[] memory assets = new string[](1);
        assets[0] = "BTC";

        uint256[] memory prices = new uint256[](1);
        prices[0] = 50000;

        vm.startPrank(owner);
        priceOracle.updatePrices(assets, prices);
        
        prices[0] = 51000;
        priceOracle.updatePrices(assets, prices);
        vm.stopPrank();

        assertEq(priceOracle.getLatestPrice("BTC"), 51000);
    }
} 
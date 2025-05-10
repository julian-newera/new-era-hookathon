// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockAttestationCenter {
    address public avsLogic;
    mapping(address => mapping(address => uint256)) public prices;

    function setAvsLogic(address _avsLogic) external {
        avsLogic = _avsLogic;
    }

    function submitPriceUpdate(address token0, address token1, uint256 price) external {
        prices[token0][token1] = price;
        prices[token1][token0] = 1e36 / price; // Inverse price
    }

    function getPrice(address token0, address token1) external view returns (uint256) {
        return prices[token0][token1];
    }
} 
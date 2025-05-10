// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract DeployPriceOracle is Script {
    function run() public returns (PriceOracle) {
        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy the PriceOracle contract
        PriceOracle priceOracle = new PriceOracle();

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log the deployed address
        console2.log("PriceOracle deployed at:", address(priceOracle));

        return priceOracle;
    }
} 
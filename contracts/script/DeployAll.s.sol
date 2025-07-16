// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {NewEraHook} from "../src/Hook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

contract DeployAll is Script {
    function run(address poolManagerAddress) public returns (address priceOracleAddr, address newEraHookAddr) {
        vm.startBroadcast();

        // 1. Deploy PriceOracle
        // PriceOracle priceOracle = new PriceOracle();
        priceOracleAddr = address(0x6f52dFd822A5Fab638e8fF7e9e7B37f030193aC6);
        console2.log("PriceOracle deployed at:", priceOracleAddr);

        // 2. Deterministically deploy NewEraHook using HookMiner
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        // Set the flags to match the hook's permissions
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManagerAddress), priceOracleAddr);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(NewEraHook).creationCode,
            constructorArgs
        );
        console2.log("Mined NewEraHook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // Deploy NewEraHook at the mined address using CREATE2
        NewEraHook newEraHook = new NewEraHook{salt: salt}(IPoolManager(poolManagerAddress), priceOracleAddr);
        newEraHookAddr = address(newEraHook);
        require(newEraHookAddr == hookAddress, "Hook address mismatch");
        console2.log("NewEraHook deployed at:", newEraHookAddr);

        vm.stopBroadcast();
    }
} 
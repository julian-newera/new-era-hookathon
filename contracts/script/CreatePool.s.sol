// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract CreatePoolScript is Script {
    function run() external {
        // Replace these with your actual values:
        uint256 deployerPrivateKey = 0x151ee9c063332f97069f4f2833c32878a3e35a77070869fae3c0c6050c055528;
        address poolManagerAddress = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;   // Uniswap v4 Pool Manager on Base Sepolia
        address usdc = 0x60D7A23033f0e2Ebd4A509FF7a50d19AE3096007;                       // USDC token address on Base Sepolia
        address usdy = 0xdd47689da802262Eaf822a94982d929c4afA16ce;                       // USDY token address on Base Sepolia
        address hookContractAddress = 0x39d84A04893dC1E73cc75696E0016BB46186b8C0; // Your already deployed hook contract

        // Set fee tier and tick spacing.
        // For example: fee = 3000 (0.3%) and tickSpacing = 60.
        uint24 fee = 500;
        int24 tickSpacing = 60;

        // For a USDC/USDY price of 1.0827, we calculate:
        // sqrt(1.0827) ≈ 1.040558, so:
        // initialSqrtPriceX96 = 1.040558 * 2^96 ≈ 82515065374000000000000000000.
        uint160 initialSqrtPriceX96 = 79228162514264337593543950336;

        // Instantiate the pool manager contract.
        IPoolManager poolManager = IPoolManager(poolManagerAddress);

        // Construct the PoolKey.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(usdy),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookContractAddress)
        });

        // If your hook requires additional data, encode it here; otherwise use an empty bytes string.
        // bytes memory hookData = "";

        // Broadcast the transaction using your hardcoded private key.
        vm.startBroadcast(deployerPrivateKey);
        poolManager.initialize(key, initialSqrtPriceX96);
        vm.stopBroadcast();
    }
}

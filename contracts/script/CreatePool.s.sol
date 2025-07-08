// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract CreatePoolScript is Script {
    function run() external {
        // Replace these with your actual values:
        uint256 deployerPrivateKey = 0x151ee9c063332f97069f4f2833c32878a3e35a77070869fae3c0c6050c055528;
        address poolManagerAddress = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;   // Uniswap v4 Pool Manager on Base Sepolia
        address usdc = 0x60D7A23033f0e2Ebd4A509FF7a50d19AE3096007;                       // USDC token address on Base Sepolia
        address usdy = 0x020dD0882F9132824bc3e5d539136D9BaacdFEd3;                       // USDY token address on Base Sepolia
        address hookContractAddress = 0xef3847D57458131Ca0f3CFC6017296cFff28e8C0; // Your already deployed hook contract

        // Set fee tier and tick spacing.
        // For example: fee = 3000 (0.3%) and tickSpacing = 60.
        uint24 fee = 200;
        int24 tickSpacing = 60;

        // For a USDC/USDY price of 1.0827, we calculate:
        // sqrt(1.0827) ≈ 1.040558, so:
        // initialSqrtPriceX96 = 1.040558 * 2^96 ≈ 82515065374000000000000000000.
        // uint160 initialSqrtPriceX96 = 79228162514264337593543950336;
        uint160 SQRT_PRICE_1 = 79228162514264337593543950336; 

        // Instantiate the pool manager contract.
        IPoolManager poolManager = IPoolManager(poolManagerAddress);

        // Construct the PoolKey.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdy),
            currency1: Currency.wrap(usdc),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // If your hook requires additional data, encode it here; otherwise use an empty bytes string.
        // bytes memory hookData = "";

        // Broadcast the transaction using your hardcoded private key.
        vm.startBroadcast(deployerPrivateKey);
        poolManager.initialize(key, SQRT_PRICE_1);

        // Instantiate the liquidity router
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);

        // IERC20Minimal(usdy).transferFrom(msg.sender, address(this), type(uint128).max);
        // IERC20Minimal(usdc).transferFrom(msg.sender, address(this), type(uint128).max);
        // IERC20Minimal(usdy).approve(address(poolManager), type(uint128).max);
        // IERC20Minimal(usdc).approve(address(poolManager), type(uint128).max);

        // Initialize the pool with sqrtPriceX96 if not already initialized
        // try poolManager.initialize(key, SQRT_PRICE_1) {
        //     // Pool initialized
        // } catch {
        //     // Assume pool is already initialized
        // }
        // int24 tickLower = -60; // Example: full range for tickSpacing=60
        // int24 tickUpper = 60;
        // int256 liquidityDelta = 1e18; // Amount of liquidity to add
        // bytes32 salt = 0;


        // IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams({
        //     tickLower: tickLower,
        //     tickUpper: tickUpper,
        //     liquidityDelta: int256(amount0 + amount1) // Simplified liquidity calc
        // });

        // poolManager.modifyPosition(key, params, hex"");
        // Approve tokens for the router
        IERC20Minimal(usdc).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(usdy).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Set your desired liquidity parameters
        int24 tickLower = -60; // Example: full range for tickSpacing=60
        int24 tickUpper = 60;
        int256 liquidityDelta = 1e18; // Amount of liquidity to add
        bytes32 salt = 0;

        // Prepare the params struct
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: salt
        });

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(key, params, "");

        vm.stopBroadcast();
    }
}

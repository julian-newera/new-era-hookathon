// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {console2} from "forge-std/console2.sol";

import {BaseScript} from "./BaseScript.sol";
import {LiquidityHelpers} from "./LiquidityHelpers.sol";
import {console2} from "forge-std/console2.sol";
import {console} from "forge-std/console.sol";

contract CreatePoolAndAddLiquidityScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;

    // address poolManagerAddress = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;   // Uniswap v4 Pool Manager on Base Sepolia
    // address usdc = 0x60D7A23033f0e2Ebd4A509FF7a50d19AE3096007;                       // USDC token address on Base Sepolia
    // address usdy = 0x020dD0882F9132824bc3e5d539136D9BaacdFEd3;                       // USDY token address on Base Sepolia
    // address hookContractAddress = 0xef3847D57458131Ca0f3CFC6017296cFff28e8C0; 
    uint256 deployerPrivateKey = 0x151ee9c063332f97069f4f2833c32878a3e35a77070869fae3c0c6050c055528;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    uint24 lpFee = 0; // 0.50%
    int24 tickSpacing = 100;
    // uint160 startingPrice = 2 ** 96; // Starting price, sqrtPriceX96; floor(sqrt(1) * 2^96)
    uint160 startingPrice = 4552702936290292383660862550846;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 1000e18;
    uint256 public token1Amount = 1000e18;

    // range of the position, must be a multiple of tickSpacing
    int24 tickLower;
    int24 tickUpper;
    /////////////////////////////////////

    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        bytes memory hookData = new bytes(0);

        int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        tickLower = ((currentTick - 750 * tickSpacing) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + 750 * tickSpacing) / tickSpacing) * tickSpacing;

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        // slippage limits
        uint256 amount0Max = token0Amount + 1;
        uint256 amount1Max = token1Amount + 1;

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, deployerAddress, hookData
        );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // Initialize Pool
        params[0] = abi.encodeWithSelector(positionManager.initializePool.selector, poolKey, startingPrice, hookData);

        // Mint Liquidity
        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 3600
        );

        // If the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast(deployerPrivateKey);
        tokenApprovals();

        // Multicall to atomically create pool & add liquidity
        positionManager.multicall{value: valueToPass}(params);
        vm.stopBroadcast();
    }
}
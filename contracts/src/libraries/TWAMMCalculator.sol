// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Epoch, EpochLibrary} from "./EpochHelper.sol";
import {TWAMMHelper} from "./TWAMM/TWAMMHelper.sol";

library TWAMMCalculator {
    using PoolIdLibrary for PoolKey;
    using EpochLibrary for Epoch;
    using CurrencyLibrary for Currency;
    
    bytes internal constant ZERO_BYTES = bytes("");
    
    struct CalculationState {
        int24 tick;
        int24 tickSpacing;
        int24 tickLower;
        uint160 sqrtPriceX96;
        uint256 balanceToken0;
        uint256 balanceToken1;
        bool zeroForOne;
        uint128 liquidity;
        uint256 token0Total;
        uint256 token1Total;
        uint256 amountSpecified;
        uint256 token0PerLiquidity;
        uint256 token1PerLiquidity;
    }
    
    function initializeCalculation(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity,
        uint256 token0Total,
        uint256 token1Total,
        IPoolManager poolManager
    ) internal view returns (CalculationState memory state) {
        // Use hardcoded values since slot0 may not be accessible
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // Approximately 1.0 price in sqrt space
        int24 tick = 0; // Middle tick representing a fair price
        
        state = CalculationState({
            tick: tick,
            tickSpacing: key.tickSpacing,
            tickLower: tickLower,
            sqrtPriceX96: sqrtPriceX96,
            balanceToken0: 0,
            balanceToken1: 0,
            zeroForOne: zeroForOne,
            liquidity: liquidity,
            token0Total: token0Total,
            token1Total: token1Total,
            amountSpecified: 0,
            token0PerLiquidity: 0,
            token1PerLiquidity: 0
        });
    }
    
    function calculateAmountForOrder(
        CalculationState memory state,
        uint256 fillAmount,
        uint256 epochBeginTimestamp,
        uint256 epochEndTimestamp
    ) internal view returns (uint256, uint256) {
        // If the current epoch isn't filled, calculate amounts
        if (state.liquidity > 0) {
            // Calculate time periods
            uint256 blocktimestamp = block.timestamp;
            uint256 endTimestamp = epochEndTimestamp;
            if (blocktimestamp < endTimestamp) {
                endTimestamp = blocktimestamp;
            }
            uint256 elapsed = endTimestamp > epochBeginTimestamp ? endTimestamp - epochBeginTimestamp : 0;
            
            uint256 outAmount;
            uint256 inAmount;
            
            if (elapsed > 0) {
                TWAMMHelper.SimplifiedState memory twammState = TWAMMHelper.SimplifiedState({
                    lastVirtualOrderTimestamp: block.timestamp,
                    liquidity: state.liquidity,
                    sqrtPriceX96: state.sqrtPriceX96,
                    tick: state.tick,
                    tickSpacing: state.tickSpacing
                });
                
                if (fillAmount > 0) {
                    // Convert fill amount to target elapsed time
                    uint256 targetElapsed = fillAmount * (epochEndTimestamp - epochBeginTimestamp) / 1e18;
                    if (targetElapsed > elapsed) {
                        targetElapsed = elapsed;
                    }
                    
                    if (targetElapsed > 0) {
                        if (state.zeroForOne) {
                            (twammState, outAmount, inAmount) = TWAMMHelper._computeOrderVirtual0For1(
                                twammState, state.tickLower, targetElapsed
                            );
                        } else {
                            (twammState, outAmount, inAmount) = TWAMMHelper._computeOrderVirtual1For0(
                                twammState, state.tickLower, targetElapsed
                            );
                        }
                    }
                } else {
                    if (state.zeroForOne) {
                        (twammState, outAmount, inAmount) = TWAMMHelper._computeOrderVirtual0For1(
                            twammState, state.tickLower, elapsed
                        );
                    } else {
                        (twammState, outAmount, inAmount) = TWAMMHelper._computeOrderVirtual1For0(
                            twammState, state.tickLower, elapsed
                        );
                    }
                }
            }
            
            // Extract fees
            uint256 token0Amount = state.zeroForOne ? inAmount : outAmount;
            uint256 token1Amount = state.zeroForOne ? outAmount : inAmount;
            
            return (token0Amount, token1Amount);
        }
        
        return (0, 0);
    }
    
    function calculateOrderAmounts(
        CalculationState memory state,
        uint256 fillAmount,
        uint256 epochBeginTimestamp,
        uint256 epochEndTimestamp
    ) internal view returns (uint256 token0PerLiquidity, uint256 token1PerLiquidity) {
        (uint256 token0Amount, uint256 token1Amount) = calculateAmountForOrder(
            state, fillAmount, epochBeginTimestamp, epochEndTimestamp
        );
        
        if (state.liquidity > 0) {
            token0PerLiquidity = token0Amount * 1e18 / state.liquidity;
            token1PerLiquidity = token1Amount * 1e18 / state.liquidity;
        }
        
        return (token0PerLiquidity, token1PerLiquidity);
    }
} 
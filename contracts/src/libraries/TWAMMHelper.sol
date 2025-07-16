// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITWAMM} from "../interfaces/ITWAMM.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {OrderPool} from "./TWAMM/OrderPool.sol";
import {TwammMath} from "./TWAMM/TwammMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {console} from "forge-std/console.sol";

library TWAMMHelper {
    using PoolIdLibrary for PoolKey;
    using TickMath for int24;
    using TickMath for uint160;
    using OrderPool for OrderPool.State;
    
    error NotInitialized();
    error ExpirationLessThanBlocktime(uint256 expiration);
    error SellRateCannotBeZero();
    error ExpirationNotOnInterval(uint256 expiration);
    error OrderAlreadyExists(ITWAMM.OrderKey orderKey);
    error OrderDoesNotExist(ITWAMM.OrderKey orderKey);
    error CannotModifyCompletedOrder(ITWAMM.OrderKey orderKey);
    error InvalidAmountDelta(ITWAMM.OrderKey orderKey, uint256 unsoldAmount, int256 amountDelta);
    error MustBeOwner(address owner, address caller);
    
    struct State {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => ITWAMM.Order) orders;
        // Parameters added for compatibility with TWAMMCalculator
        uint128 liquidity;
        uint160 sqrtPriceX96;
        int24 tick;
        int24 tickSpacing;
    }
    
    // Simplified state without mappings for memory usage
    struct SimplifiedState {
        uint256 lastVirtualOrderTimestamp;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        int24 tick;
        int24 tickSpacing;
    }
    
    struct PoolParamsOnExecute {
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    struct ExecutionUpdateParams {
        uint256 secondsElapsedX96;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 sellRate0For1;
        uint256 sellRate1For0;
    }
    
    struct AdvanceParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
    }

    struct AdvanceSingleParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
        bool zeroForOne;
    }

    struct TickCrossingParams {
        int24 initializedTick;
        uint256 nextTimestamp;
        uint256 secondsElapsedX96;
        PoolParamsOnExecute pool;
    }
    
    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96,
        IPoolManager poolManager
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        nextTickInit = TickMath.getTickAtSqrtPrice(pool.sqrtPriceX96);
        int24 targetTick = TickMath.getTickAtSqrtPrice(nextSqrtPriceX96);
        bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
        bool nextTickInitFurtherThanTarget = false;

        while (!nextTickInitFurtherThanTarget) {
            unchecked {
                if (searchingLeft) nextTickInit -= 1;
            }
            
            int16 wordPos = int16(nextTickInit >> 8);
            bytes32 wordSlot = keccak256(abi.encode(poolKey.toId(), wordPos));
            console.log("step 2", nextTickInit);
            bytes32 wordData = poolManager.extsload(wordSlot);
            
            uint256 bitPos = uint256(uint24(nextTickInit % 256));
            uint256 mask = searchingLeft ? (1 << bitPos) - 1 : type(uint256).max << (bitPos + 1);
            uint256 maskedWord = uint256(wordData) & mask;
            
            if (maskedWord != 0) {
                bitPos = searchingLeft ? bitPos - 1 : bitPos + 1;
                while (maskedWord != 0) {
                    if (maskedWord & (1 << bitPos) != 0) {
                        int24 tickOffset = int24(uint24(bitPos));
                        nextTickInit = int24(wordPos) * 256 + tickOffset;
                        crossingInitializedTick = true;
                        break;
                    }
                    bitPos = searchingLeft ? bitPos - 1 : bitPos + 1;
                }
            } else {
                nextTickInit = searchingLeft ? 
                    int24(wordPos * 256 - 1) : 
                    int24((wordPos + 1) * 256);
            }
            
            nextTickInitFurtherThanTarget = searchingLeft ? nextTickInit <= targetTick : nextTickInit > targetTick;
            if (crossingInitializedTick) break;
        }
        if (nextTickInitFurtherThanTarget) crossingInitializedTick = false;
    }

     function calculateOrderAmounts(uint256 amount, PoolKey calldata key) external pure returns (uint256 baseAmount, uint256 totalAmount) {
        uint256 poolFee = key.fee;
        uint256 fee = (amount * poolFee) / 10000;
        baseAmount = amount;
        totalAmount = amount + fee;
        return (baseAmount, totalAmount);
    }

    function _advanceTimeThroughTickCrossing(
        OrderPool.State storage orderPool0For1,
        OrderPool.State storage orderPool1For0,
        PoolKey memory poolKey,
        TickCrossingParams memory params,
        IPoolManager poolManager
    ) public returns (PoolParamsOnExecute memory, uint256) {
        uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(params.initializedTick);
        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPrice,
            orderPool0For1.sellRateCurrent,
            orderPool1For0.sellRateCurrent
        );
        (uint256 earningsFactorPool0, uint256 earningsFactorPool1) = TwammMath.calculateEarningsUpdates(
            TwammMath.ExecutionUpdateParams(
                secondsUntilCrossingX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                orderPool0For1.sellRateCurrent,
                orderPool1For0.sellRateCurrent
            ),
            initializedSqrtPrice
        );
        orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
        orderPool1For0.advanceToCurrentTime(earningsFactorPool1);
        bytes32 tickSlot = keccak256(abi.encode(poolKey.toId(), params.initializedTick));
        bytes32 tickData = poolManager.extsload(tickSlot);
        int128 liquidityNet = int128(uint128(uint256(tickData)));
        if (initializedSqrtPrice < params.pool.sqrtPriceX96) {
            liquidityNet = -liquidityNet;
        }
        params.pool.liquidity = liquidityNet < 0
            ? params.pool.liquidity - uint128(-liquidityNet)
            : params.pool.liquidity + uint128(liquidityNet);
        params.pool.sqrtPriceX96 = initializedSqrtPrice;
        return (params.pool, secondsUntilCrossingX96);
    }
    function _advanceTimestampForSinglePoolSell(
        OrderPool.State storage orderPool0For1,
        OrderPool.State storage orderPool1For0,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params,
        IPoolManager poolManager
    ) public returns (PoolParamsOnExecute memory) {
        OrderPool.State storage orderPool = params.zeroForOne ? orderPool0For1 : orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
        uint256 totalEarnings;
        while (true) {
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );
            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96, poolManager);
            console.log("step", crossingInitializedTick);
            if (crossingInitializedTick) {
                bytes32 tickSlot = keccak256(abi.encode(poolKey.toId(), tick));
                bytes32 tickData = poolManager.extsload(tickSlot);
                int128 liquidityNetAtTick = int128(uint128(uint256(tickData)));
                uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(tick);
                uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );
                uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );
                if (params.zeroForOne) liquidityNetAtTick = -liquidityNetAtTick;
                params.pool.liquidity = LiquidityMath.addDelta(params.pool.liquidity, liquidityNetAtTick);
                params.pool.sqrtPriceX96 = initializedSqrtPrice;
                unchecked {
                    totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                if (params.zeroForOne) {
                    totalEarnings += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                }
                uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / sellRateCurrent;
                if (params.nextTimestamp % params.expirationInterval == 0) {
                    orderPool.advanceToInterval(params.nextTimestamp, accruedEarningsFactor);
                } else {
                    orderPool.advanceToCurrentTime(accruedEarningsFactor);
                }
                params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                break;
            }
        }
        return params.pool;
    }
    function _advanceToNewTimestamp(
        OrderPool.State storage orderPool0For1Input,
        OrderPool.State storage orderPool1For0Input,
        PoolKey memory poolKey,
        AdvanceParams memory params,
        IPoolManager poolManager
    ) public returns (PoolParamsOnExecute memory) {
        uint160 finalSqrtPriceX96;
        uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;
        OrderPool.State storage orderPool0For1 = orderPool0For1Input;
        OrderPool.State storage orderPool1For0 = orderPool1For0Input;
        while (true) {
            TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams(
                secondsElapsedX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                orderPool0For1.sellRateCurrent,
                orderPool1For0.sellRateCurrent
            );
            finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);
            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96, poolManager);
            
            if (crossingInitializedTick) {
                (params.pool, secondsElapsedX96) = _advanceTimeThroughTickCrossing(
                    orderPool0For1Input, orderPool1For0Input, poolKey, TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool), poolManager
                );
            } else {
                (uint256 earningsFactorPool0, uint256 earningsFactorPool1) =
                    TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

                if (params.nextTimestamp % params.expirationInterval == 0) {
                    orderPool0For1.advanceToInterval(params.nextTimestamp, earningsFactorPool0);
                    orderPool1For0.advanceToInterval(params.nextTimestamp, earningsFactorPool1);
                } else {
                    orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
                    orderPool1For0.advanceToCurrentTime(earningsFactorPool1);
                }
                params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                break;
            }
        }
        return params.pool;
    }
} 
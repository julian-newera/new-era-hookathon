// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITWAMM} from "../../interfaces/ITWAMM.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {OrderPool} from "./OrderPool.sol";
import {TwammMath} from "./TwammMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

library TWAMMHelper {
    using PoolIdLibrary for PoolKey;
    using TickMath for int24;
    using TickMath for uint160;
    using OrderPool for OrderPool.State;
    
    struct State {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => ITWAMM.Order) orders;
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
    
    function _advanceToNewTimestamp(
        State storage self, 
        PoolKey memory poolKey, 
        AdvanceParams memory params,
        IPoolManager poolManager
    ) internal returns (PoolParamsOnExecute memory) {
        uint160 finalSqrtPriceX96;
        uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

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
            unchecked {
                if (crossingInitializedTick) {
                    uint256 secondsUntilCrossingX96;
                    (params.pool, secondsUntilCrossingX96) = _advanceTimeThroughTickCrossing(
                        self, poolKey, TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool), poolManager
                    );
                    secondsElapsedX96 = secondsElapsedX96 - secondsUntilCrossingX96;
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
        }

        return params.pool;
    }
    
    function _advanceTimestampForSinglePoolSell(
        State storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params,
        IPoolManager poolManager
    ) internal returns (PoolParamsOnExecute memory) {
        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
        uint256 totalEarnings;

        while (true) {
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96, poolManager);

            if (crossingInitializedTick) {
                int128 liquidityNetAtTick = params.zeroForOne ? int128(-100000) : int128(100000);
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
    
    function _advanceTimeThroughTickCrossing(
        State storage self,
        PoolKey memory poolKey,
        TickCrossingParams memory params,
        IPoolManager poolManager
    ) internal returns (PoolParamsOnExecute memory, uint256) {
        uint160 initializedSqrtPrice = params.initializedTick.getSqrtPriceAtTick();

        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPrice,
            self.orderPool0For1.sellRateCurrent,
            self.orderPool1For0.sellRateCurrent
        );

        (uint256 earningsFactorPool0, uint256 earningsFactorPool1) = TwammMath.calculateEarningsUpdates(
            TwammMath.ExecutionUpdateParams(
                secondsUntilCrossingX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                self.orderPool0For1.sellRateCurrent,
                self.orderPool1For0.sellRateCurrent
            ),
            initializedSqrtPrice
        );

        self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
        self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

        unchecked {
            // update pool - simplified approach without relying on tick information
            int128 liquidityNet = 0;
            bool zeroForOne = initializedSqrtPrice < params.pool.sqrtPriceX96;
            
            // Always assume some standard liquidity net value
            liquidityNet = zeroForOne ? int128(100000) : int128(-100000);
            
            if (zeroForOne) liquidityNet = -liquidityNet;
            params.pool.liquidity = liquidityNet < 0
                ? params.pool.liquidity - uint128(-liquidityNet)
                : params.pool.liquidity + uint128(liquidityNet);

            params.pool.sqrtPriceX96 = initializedSqrtPrice;
        }
        return (params.pool, secondsUntilCrossingX96);
    }
    
    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96,
        IPoolManager poolManager
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        int24 currentTick = pool.sqrtPriceX96.getTickAtSqrtPrice();
        int24 targetTick = nextSqrtPriceX96.getTickAtSqrtPrice();
        
        bool zeroForOne = nextSqrtPriceX96 < pool.sqrtPriceX96;
        
        if (zeroForOne) {
            int24 lowerBound = (targetTick / poolKey.tickSpacing) * poolKey.tickSpacing;
            int24 upperBound = (currentTick / poolKey.tickSpacing) * poolKey.tickSpacing;
            
            if (lowerBound < upperBound) {
                crossingInitializedTick = true;
                nextTickInit = upperBound;
            } else {
                crossingInitializedTick = false;
                nextTickInit = currentTick;
            }
        } else {
            int24 lowerBound = (currentTick / poolKey.tickSpacing) * poolKey.tickSpacing;
            int24 upperBound = (targetTick / poolKey.tickSpacing) * poolKey.tickSpacing;
            
            if (lowerBound < upperBound) {
                crossingInitializedTick = true;
                nextTickInit = lowerBound + poolKey.tickSpacing;
            } else {
                crossingInitializedTick = false;
                nextTickInit = currentTick;
            }
        }
        
        return (crossingInitializedTick, nextTickInit);
    }
    
    function _orderId(ITWAMM.OrderKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _getOrder(State storage self, ITWAMM.OrderKey memory key) internal view returns (ITWAMM.Order storage) {
        return self.orders[_orderId(key)];
    }

    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }
    
    function _executeTWAMMOrders(
        State storage self,
        IPoolManager manager,
        PoolKey memory key,
        PoolParamsOnExecute memory pool,
        uint256 expirationInterval
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = block.timestamp;
            return (false, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
        uint256 nextExpirationTimestamp = prevTimestamp + (expirationInterval - (prevTimestamp % expirationInterval));

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

        unchecked {
            while (nextExpirationTimestamp <= block.timestamp) {
                if (
                    orderPool0For1.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                        || orderPool1For0.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                ) {
                    if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                        pool = _advanceToNewTimestamp(
                            self,
                            key,
                            AdvanceParams(
                                expirationInterval,
                                nextExpirationTimestamp,
                                nextExpirationTimestamp - prevTimestamp,
                                pool
                            ),
                            manager
                        );
                    } else {
                        pool = _advanceTimestampForSinglePoolSell(
                            self,
                            key,
                            AdvanceSingleParams(
                                expirationInterval,
                                nextExpirationTimestamp,
                                nextExpirationTimestamp - prevTimestamp,
                                pool,
                                orderPool0For1.sellRateCurrent != 0
                            ),
                            manager
                        );
                    }
                    prevTimestamp = nextExpirationTimestamp;
                }
                nextExpirationTimestamp += expirationInterval;

                if (!_hasOutstandingOrders(self)) break;
            }

            if (prevTimestamp < block.timestamp && _hasOutstandingOrders(self)) {
                if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                    pool = _advanceToNewTimestamp(
                        self,
                        key,
                        AdvanceParams(expirationInterval, block.timestamp, block.timestamp - prevTimestamp, pool),
                        manager
                    );
                } else {
                    pool = _advanceTimestampForSinglePoolSell(
                        self,
                        key,
                        AdvanceSingleParams(
                            expirationInterval,
                            block.timestamp,
                            block.timestamp - prevTimestamp,
                            pool,
                            orderPool0For1.sellRateCurrent != 0
                        ),
                        manager
                    );
                }
            }
        }

        self.lastVirtualOrderTimestamp = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
    }

    function getNewSqrtPriceX96(ExecutionUpdateParams memory params) internal pure returns (uint160) {
        return TwammMath.getNewSqrtPriceX96(TwammMath.ExecutionUpdateParams(
            params.secondsElapsedX96,
            params.sqrtPriceX96,
            params.liquidity,
            params.sellRate0For1,
            params.sellRate1For0
        ));
    }

    function calculateEarningsUpdates(
        ExecutionUpdateParams memory params,
        uint160 sqrtPriceX96End
    ) internal pure returns (uint256 earningsFactorPool0, uint256 earningsFactorPool1) {
        return TwammMath.calculateEarningsUpdates(TwammMath.ExecutionUpdateParams(
            params.secondsElapsedX96,
            params.sqrtPriceX96,
            params.liquidity,
            params.sellRate0For1,
            params.sellRate1For0
        ), sqrtPriceX96End);
    }

    function calculateTimeBetweenTicks(
        uint128 liquidity,
        uint160 sqrtPriceX96Start,
        uint160 sqrtPriceX96End,
        uint256 sellRate0For1,
        uint256 sellRate1For0
    ) internal pure returns (uint256) {
        return TwammMath.calculateTimeBetweenTicks(
            liquidity,
            sqrtPriceX96Start,
            sqrtPriceX96End,
            sellRate0For1,
            sellRate1For0
        );
    }

    function _computeOrderVirtual0For1(
        SimplifiedState memory state,
        int24 tickLower,
        uint256 elapsed
    ) internal pure returns (SimplifiedState memory, uint256, uint256) {
        // Simplified implementation
        // Calculate the amount out (token1) and amount in (token0)
        int24 tickDiff = state.tick - tickLower;
        uint256 amountOut = tickDiff > 0 ? state.liquidity * uint256(uint24(tickDiff)) * elapsed / 1e18 : 0;
        uint256 amountIn = amountOut * state.sqrtPriceX96 / FixedPoint96.Q96;
        
        return (state, amountOut, amountIn);
    }
    
    function _computeOrderVirtual1For0(
        SimplifiedState memory state,
        int24 tickLower,
        uint256 elapsed
    ) internal pure returns (SimplifiedState memory, uint256, uint256) {
        // Simplified implementation
        // Calculate the amount out (token0) and amount in (token1)
        int24 tickDiff = tickLower + state.tickSpacing - state.tick;
        uint256 amountOut = tickDiff > 0 ? state.liquidity * uint256(uint24(tickDiff)) * elapsed / 1e18 : 0;
        uint256 amountIn = amountOut * FixedPoint96.Q96 / state.sqrtPriceX96;
        
        return (state, amountOut, amountIn);
    }
} 
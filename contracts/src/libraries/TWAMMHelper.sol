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
    
    // Basic stubs for functions used in TWAMMCalculator
    
    function _orderId(ITWAMM.OrderKey memory orderKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(orderKey));
    }
    
    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96,
        IPoolManager poolManager
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        // Simplified implementation
        return (false, 0);
    }
    
    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent > 0 || self.orderPool1For0.sellRateCurrent > 0;
    }
    
    function _getOrder(State storage self, ITWAMM.OrderKey memory key) internal view returns (ITWAMM.Order storage) {
        return self.orders[_orderId(key)];
    }
    
    function _executeTWAMMOrders(
        State storage self,
        IPoolManager poolManager,
        PoolKey memory key,
        PoolParamsOnExecute memory pool,
        uint256 expirationInterval
    ) internal returns (bool zeroForOne, uint160 sqrtPriceLimitX96) {
        // Simplified implementation
        return (false, 0);
    }
    
    function _advanceToNewTimestamp(
        State storage self,
        PoolKey memory poolKey,
        AdvanceParams memory params,
        IPoolManager poolManager
    ) internal returns (PoolParamsOnExecute memory) {
        // Simplified implementation
        return params.pool;
    }
    
    function _advanceTimestampForSinglePoolSell(
        State storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params,
        IPoolManager poolManager
    ) internal returns (PoolParamsOnExecute memory) {
        // Simplified implementation
        return params.pool;
    }
    
    function _advanceTimeThroughTickCrossing(
        State storage self,
        PoolKey memory poolKey,
        TickCrossingParams memory params,
        IPoolManager poolManager
    ) internal returns (PoolParamsOnExecute memory, uint256) {
        // Simplified implementation
        return (params.pool, 0);
    }
    
    function _computeOrderVirtual0For1(
        SimplifiedState memory state,
        int24 tickLower,
        uint256 elapsed
    ) internal pure returns (SimplifiedState memory, uint256, uint256) {
        // Simplified implementation
        return (state, 0, 0);
    }
    
    function _computeOrderVirtual1For0(
        SimplifiedState memory state,
        int24 tickLower,
        uint256 elapsed
    ) internal pure returns (SimplifiedState memory, uint256, uint256) {
        // Simplified implementation
        return (state, 0, 0);
    }
    
    // Create a simplified state from storage state
    function createSimplifiedState(State storage self) internal view returns (SimplifiedState memory) {
        return SimplifiedState({
            lastVirtualOrderTimestamp: self.lastVirtualOrderTimestamp,
            liquidity: self.liquidity,
            sqrtPriceX96: self.sqrtPriceX96,
            tick: self.tick,
            tickSpacing: self.tickSpacing
        });
    }
} 
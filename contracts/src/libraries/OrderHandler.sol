// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Epoch, EpochLibrary, EpochHelper} from "./EpochHelper.sol";

library OrderHandler {
    using PoolIdLibrary for PoolKey;
    using EpochLibrary for Epoch;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    
    bytes internal constant ZERO_BYTES = bytes("");
    
    error ZeroLiquidity();
    error InRange();
    error CrossedRange();
    error Filled();
    
    event Kill(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );
    
    function unlockCallbackPlace(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        int256 liquidityDelta,
        address owner,
        IPoolManager poolManager
    ) external {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: liquidityDelta,
                salt: 0
            }),
            ZERO_BYTES
        );

        if (delta.amount0() < 0) {
            if (delta.amount1() != 0) revert InRange();
            if (!zeroForOne) revert CrossedRange();
            key.currency0.settle(poolManager, owner, uint256(uint128(-delta.amount0())), false);
        } else {
            if (delta.amount0() != 0) revert InRange();
            if (zeroForOne) revert CrossedRange();
            key.currency1.settle(poolManager, owner, uint256(uint128(-delta.amount1())), false);
        }
    }
    
    function processKill(
        PoolKey calldata key, 
        int24 tickLower, 
        bool zeroForOne, 
        address to,
        Epoch epoch,
        mapping(Epoch => EpochHelper.EpochInfo) storage epochInfos,
        IPoolManager poolManager
    ) internal {
        EpochHelper.EpochInfo storage epochInfo = epochInfos[epoch];

        if (epochInfo.filled) revert Filled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];

        // Apply direct call to unlockCallbackKill via pool manager
        int24 tickUpper = tickLower + key.tickSpacing;
        uint256 amount0Fee = 0;
        uint256 amount1Fee = 0;
        
        // First collect any accumulated fees if needed
        if (liquidity != epochInfo.liquidityTotal) {
            (, BalanceDelta deltaFee) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: 0,
                    salt: 0
                }),
                ZERO_BYTES
            );

            if (deltaFee.amount0() > 0) {
                poolManager.mint(address(this), key.currency0.toId(), uint256(uint128(deltaFee.amount0())));
                amount0Fee = uint256(uint128(deltaFee.amount0()));
            }
            if (deltaFee.amount1() > 0) {
                poolManager.mint(address(this), key.currency1.toId(), uint256(uint128(deltaFee.amount1())));
                amount1Fee = uint256(uint128(deltaFee.amount1()));
            }
        }
        
        // Now remove the position
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: 0
            }),
            ZERO_BYTES
        );

        if (delta.amount0() > 0) {
            key.currency0.take(poolManager, to, uint256(uint128(delta.amount0())), false);
        }
        if (delta.amount1() > 0) {
            key.currency1.take(poolManager, to, uint256(uint128(delta.amount1())), false);
        }
        
        epochInfo.liquidityTotal -= liquidity;
        unchecked {
            epochInfo.token0Total += amount0Fee;
            epochInfo.token1Total += amount1Fee;
        }

        emit Kill(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }
} 
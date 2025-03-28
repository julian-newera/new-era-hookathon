// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Epoch, EpochLibrary, EpochHelper} from "./EpochHelper.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ITWAMM} from "../interfaces/ITWAMM.sol";

library EpochHandler {
    using PoolIdLibrary for PoolKey;
    using EpochLibrary for Epoch;
    using CurrencyLibrary for Currency;
    
    bytes internal constant ZERO_BYTES = bytes("");
    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);
    
    error NotFilled();
    error ZeroLiquidity();
    
    event Place(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );
    
    event Fill(Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne);
    
    event Withdraw(address indexed owner, Epoch indexed epoch, uint128 liquidity);
    
    function processPlace(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        address sender,
        uint128 liquidity,
        Epoch epochNext,
        mapping(bytes32 => Epoch) storage epochs,
        mapping(Epoch => EpochHelper.EpochInfo) storage epochInfos,
        IPoolManager poolManager
    ) internal returns (Epoch) {
        EpochHelper.EpochInfo storage epochInfo;
        Epoch epoch = epochs[EpochHelper.getEpochKey(key, tickLower, zeroForOne)];
        
        if (epoch.equals(EPOCH_DEFAULT)) {
            unchecked {
                epochs[EpochHelper.getEpochKey(key, tickLower, zeroForOne)] = epoch = epochNext;
                epochNext = epoch.unsafeIncrement();
            }
            epochInfo = epochInfos[epoch];
            epochInfo.currency0 = key.currency0;
            epochInfo.currency1 = key.currency1;
        } else {
            epochInfo = epochInfos[epoch];
        }

        unchecked {
            epochInfo.liquidityTotal += liquidity;
            epochInfo.liquidity[sender] += liquidity;
        }

        emit Place(sender, epoch, key, tickLower, zeroForOne, liquidity);
        
        return epoch;
    }
    
    function processFill(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        Epoch epoch,
        mapping(bytes32 => Epoch) storage epochs,
        mapping(Epoch => EpochHelper.EpochInfo) storage epochInfos,
        IPoolManager poolManager
    ) internal {
        if (!epoch.equals(EPOCH_DEFAULT)) {
            EpochHelper.EpochInfo storage epochInfo = epochInfos[epoch];
            
            epochInfo.filled = true;
            
            // Apply the liquidity modification
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: -int256(uint256(epochInfo.liquidityTotal)),
                    salt: 0
                }),
                ZERO_BYTES
            );
            
            uint256 amount0 = 0;
            uint256 amount1 = 0;
            
            if (delta.amount0() > 0) {
                poolManager.mint(address(this), key.currency0.toId(), uint256(uint128(delta.amount0())));
                amount0 = uint256(uint128(delta.amount0()));
            }
            if (delta.amount1() > 0) {
                poolManager.mint(address(this), key.currency1.toId(), uint256(uint128(delta.amount1())));
                amount1 = uint256(uint128(delta.amount1()));
            }
            
            unchecked {
                epochInfo.token0Total += amount0;
                epochInfo.token1Total += amount1;
            }
            
            epochs[EpochHelper.getEpochKey(key, tickLower, zeroForOne)] = EPOCH_DEFAULT;
            
            emit Fill(epoch, key, tickLower, zeroForOne);
        }
    }
    
    function processWithdraw(
        Epoch epoch, 
        address to, 
        address sender,
        mapping(Epoch => EpochHelper.EpochInfo) storage epochInfos,
        IPoolManager poolManager
    ) internal returns (uint256 amount0, uint256 amount1) {
        EpochHelper.EpochInfo storage epochInfo = epochInfos[epoch];
        
        if (!epochInfo.filled) revert NotFilled();
        
        uint128 liquidity = epochInfo.liquidity[sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[sender];
        
        uint128 liquidityTotal = epochInfo.liquidityTotal;
        
        amount0 = FullMath.mulDiv(epochInfo.token0Total, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(epochInfo.token1Total, liquidity, liquidityTotal);
        
        epochInfo.token0Total -= amount0;
        epochInfo.token1Total -= amount1;
        epochInfo.liquidityTotal = liquidityTotal - liquidity;
        
        if (amount0 > 0) {
            poolManager.burn(address(this), epochInfo.currency0.toId(), amount0);
            poolManager.take(epochInfo.currency0, to, amount0);
        }
        if (amount1 > 0) {
            poolManager.burn(address(this), epochInfo.currency1.toId(), amount1);
            poolManager.take(epochInfo.currency1, to, amount1);
        }
        
        emit Withdraw(sender, epoch, liquidity);
    }
} 
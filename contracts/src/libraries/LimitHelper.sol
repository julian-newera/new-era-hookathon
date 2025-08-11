// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

library LimitHelper {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    // Events
    event LimitOrderPlaced(
        PoolId poolId,
        address user,
        uint256 orderId,
        uint256 amount,
        uint256 oraclePrice,
        uint256 tolerance
    );
    // Errors
    error InvalidTolerance();
    error InvalidAmount();
    error TooManyOrders();
    // Constants
    uint256 constant MAX_ORDERS_PER_USER = 60;
    function validateLimitOrder(
        uint256 baseAmount,
        uint256 tolerance,
        uint256 userOrderCount
    ) external pure {
        if (baseAmount == 0) revert InvalidAmount();
        if (tolerance > 10_000) revert InvalidTolerance();
        if (userOrderCount >= MAX_ORDERS_PER_USER) {
            revert TooManyOrders();
        }
    }
    function getOraclePrice(
        PoolKey calldata key,
        IPriceOracle priceOracle
    ) external view returns (uint256 oraclePrice) {
        oraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency0)).name()
        );
    }
    function getOraclePrice2(
        PoolKey calldata key,
        IPriceOracle priceOracle
    ) external view returns (uint256 oraclePrice) {
        oraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );
    }
    function transferTokens(
        PoolKey calldata key,
        uint256 totalAmount,
        bool zeroForOne,
        address sender
    ) external {
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        ERC20 tokenContract = ERC20(Currency.unwrap(token));
        tokenContract.transferFrom(sender, address(this), totalAmount);
    }
    function emitLimitOrderPlaced(
        PoolId poolId,
        address user,
        uint256 orderId,
        uint256 amount,
        uint256 oraclePrice,
        uint256 tolerance
    ) external {
        emit LimitOrderPlaced(
            poolId,
            user,
            orderId,
            amount,
            oraclePrice,
            tolerance
        );
    }

    
}
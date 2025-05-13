// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IExtsload} from "v4-core/src/interfaces/IExtsload.sol";

contract NewEraHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Events
    event LimitOrderPlaced(
        PoolId poolId,
        address user,
        uint256 amount,
        uint256 oraclePrice,
        uint256 tolerance
    );
    event LimitOrderExecuted(
        PoolId poolId,
        address user,
        uint256 amount,
        uint256 executionPrice
    );
    event LimitOrderCancelled(
        PoolId poolId,
        address user,
        uint256 amount
    );

    // Structs
    struct LimitOrder {
        address user;
        uint256 amount;
        uint256 oraclePrice;
        uint256 tolerance;
        bool zeroForOne;
        bool isActive;
        bool tokensTransferred;
    }

    // Storage
    mapping(PoolId => mapping(address => LimitOrder)) public limitOrders;
    IPriceOracle public immutable priceOracle;

    // Errors
    error InvalidTolerance();
    error NoActiveLimitOrder();
    error UnauthorizedCaller();
    error InvalidAmount();
    error PriceAboveLimit();

    constructor(
        IPoolManager _poolManager,
        address _priceOracle
    ) BaseHook(_poolManager) {
        priceOracle = IPriceOracle(_priceOracle);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Prevent recursive calls
        if (sender == address(this)) {
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Decode tolerance from hookData
        uint256 tolerance = abi.decode(hookData, (uint256));

        // Get current pool price
        address poolAddress = address(uint160(uint256(keccak256(abi.encode(key.toId())))));
        bytes32 slot0 = IExtsload(poolAddress).extsload(bytes32(uint256(0)));
        int24 currentTick = int24(uint24(uint256(slot0)));
        uint160 currentPrice = TickMath.getSqrtPriceAtTick(currentTick);

        // Get oracle price
        uint256 oraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );

        // Calculate price limit
        uint256 priceLimit;
        if (tolerance == 0) {
            priceLimit = oraclePrice; // Exact price match required
        } else {
            priceLimit = oraclePrice + (oraclePrice * tolerance) / 100;
        }

        // Check if user already has an active limit order for this pool
        LimitOrder storage existingOrder = limitOrders[key.toId()][sender];
        
        if (existingOrder.isActive) {
            // If price is good, execute the existing order
            if (currentPrice <= priceLimit) {
                _executeLimitOrder(key, existingOrder);
            } else {
                revert("Active limit order already exists");
            }
        } else {
            // Create new limit order if none exists
            _createLimitOrder(key, params.amountSpecified, oraclePrice, tolerance, params.zeroForOne);
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _executeLimitOrder(
        PoolKey memory key,
        LimitOrder storage order
    ) internal {
        // Check if tokens need to be transferred
        if (!order.tokensTransferred) {
            Currency tokenToSell = order.zeroForOne ? key.currency0 : key.currency1;
            
            // Transfer tokens using pool manager
            poolManager.sync(tokenToSell);
            poolManager.take(tokenToSell, address(this), order.amount);
            order.tokensTransferred = true;
        }

        // Rest of the execution code...
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: int256(order.amount),
            sqrtPriceLimitX96: order.zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // Execute swap
        BalanceDelta delta = poolManager.swap(key, params, "");

        // Handle token transfers
        if (order.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        // Clear the order
        order.isActive = false;

        // Get current tick for event emission
        address poolAddress = address(uint160(uint256(keccak256(abi.encode(key.toId())))));
        bytes32 slot0 = IExtsload(poolAddress).extsload(bytes32(uint256(0)));
        int24 currentTick = int24(uint24(uint256(slot0)));

        emit LimitOrderExecuted(
            key.toId(),
            order.user,
            order.amount,
            TickMath.getSqrtPriceAtTick(currentTick)
        );
    }

    function _createLimitOrder(
        PoolKey memory key,
        int256 amountSpecified,
        uint256 oraclePrice,
        uint256 tolerance,
        bool zeroForOne
    ) internal {
        if (amountSpecified <= 0) revert InvalidAmount();
        if (oraclePrice > 10000) revert InvalidTolerance(); // Max 100% tolerance

        PoolId poolId = key.toId();
        
        // Create limit order using the passed oraclePrice
        limitOrders[poolId][msg.sender] = LimitOrder({
            user: msg.sender,
            amount: uint256(amountSpecified),
            oraclePrice: oraclePrice,
            tolerance: tolerance,
            zeroForOne: zeroForOne,
            isActive: true,
            tokensTransferred: false
        });

        // Transfer tokens using pool manager
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        poolManager.sync(token);
        poolManager.take(token, address(this), uint256(amountSpecified));
        
        // Set tokensTransferred to true after successful transfer
        limitOrders[poolId][msg.sender].tokensTransferred = true;

        emit LimitOrderPlaced(poolId, msg.sender, uint256(amountSpecified), oraclePrice, tolerance);
    }

    function updateLimitOrder(
        PoolKey calldata key,
        uint256 newAmount,
        uint256 newTolerance
    ) external {
        PoolId poolId = key.toId();
        LimitOrder storage order = limitOrders[poolId][msg.sender];

        if (!order.isActive) revert NoActiveLimitOrder();
        if (order.user != msg.sender) revert UnauthorizedCaller();
        if (newTolerance > 100) revert InvalidTolerance();
        if (newAmount == 0) revert InvalidAmount();

        // Update the order
        order.amount = newAmount;
        order.tolerance = newTolerance;

        emit LimitOrderPlaced(poolId, msg.sender, newAmount, order.oraclePrice, newTolerance);
    }

    function cancelLimitOrder(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        LimitOrder storage order = limitOrders[poolId][msg.sender];

        if (!order.isActive) revert NoActiveLimitOrder();
        if (order.user != msg.sender) revert UnauthorizedCaller();

        // Return tokens to user if they were transferred
        if (order.tokensTransferred) {
            Currency token = order.zeroForOne ? key.currency0 : key.currency1;
            token.transfer(msg.sender, order.amount);
        }

        // Clear the order
        delete limitOrders[poolId][msg.sender];

        emit LimitOrderCancelled(poolId, msg.sender, order.amount);
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
}
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
import "forge-std/console.sol";
import {TWAMMHelper} from "./libraries/TWAMMHelper.sol";

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
    event LimitOrderCancelled(PoolId poolId, address user, uint256 amount);

    // Structs
    struct LimitOrder {
        address user;
        uint256 amount;
        uint256 totalAmount; // Store total amount including fees
        uint256 oraclePrice;
        uint256 tolerance;
        bool zeroForOne;
        bool isActive;
        bool tokensTransferred;
    }

    // Storage
    mapping(PoolId => mapping(address => LimitOrder)) public limitOrders;
    IPriceOracle public immutable priceOracle;
    mapping(PoolId => TWAMMHelper.State) internal twammStates;
    mapping(PoolId => address) public poolAddresses;

    // Errors
    error InvalidTolerance();
    error NoActiveLimitOrder();
    error UnauthorizedCaller();
    error InvalidAmount();
    error PriceAboveLimit();
    error LimitOrderConditionsNotMet();

    constructor(
        IPoolManager _poolManager,
        address _priceOracle
    ) BaseHook(_poolManager) {
        priceOracle = IPriceOracle(_priceOracle);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal virtual override returns (bytes4) {
        // Initialize TWAMM state for this pool
        PoolId poolId = key.toId();
        TWAMMHelper.State storage twamm = twammStates[poolId];
        twamm.lastVirtualOrderTimestamp = block.timestamp;

        // Store pool address
        poolAddresses[poolId] = address(
            uint160(uint256(keccak256(abi.encode(poolId))))
        );

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
       

        if (sender == address(this)) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Decode the order owner's address from hookData
        address orderOwner = abi.decode(hookData, (address));

        PoolId poolId = key.toId();

        // Check for orders under the order owner's address
        LimitOrder storage order = limitOrders[poolId][orderOwner];
        if (!order.isActive) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }


        // Get current price from swap parameters
        uint160 sqrtPriceX96 = params.sqrtPriceLimitX96;
        uint256 currentPrice = (uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96) *
            1e18) >> 192;

        // Scale oracle price to match pool price scale (1e18)
        uint256 scaledOraclePrice = (order.oraclePrice * 1e18) / 100; // Convert from 100 to 1.00
        uint256 scaledTolerance = (order.tolerance * 1e18) / 10000; // Convert basis points to percentage
        console.log("scaledOraclePrice", scaledOraclePrice);
        console.log("scaledTolerance", scaledTolerance);

        // Calculate price limit based on oracle price and tolerance
        uint256 priceLimit = order.zeroForOne
            ? scaledOraclePrice - scaledTolerance // For sell orders
            : scaledOraclePrice + scaledTolerance; // For buy orders

        // For buy orders (zeroForOne: false), execute when price goes up
        // For sell orders (zeroForOne: true), execute when price goes down
        bool shouldExecute = (order.zeroForOne && currentPrice <= priceLimit) ||
            (!order.zeroForOne && currentPrice >= priceLimit);
        

        if (shouldExecute) {
            _executeLimitOrder(key, order);
            // Set isActive to false after execution
            order.isActive = false;
        } else {
            revert LimitOrderConditionsNotMet();
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }


    // function _afterSwap(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     BalanceDelta delta,
    //     bytes calldata hookData
    // ) internal override {   

    // }

    function placeOrder(
        PoolKey calldata key,
        uint256 baseAmount,
        uint256 totalAmount,
        uint256 tolerance,
        bool zeroForOne
    ) external {
        if (baseAmount == 0) revert InvalidAmount();
        if (tolerance > 10_000) revert InvalidTolerance();

        // Get oracle price
        uint256 oraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );

        // check if user already has an active limit order for this pool
        LimitOrder storage existingOrder = limitOrders[key.toId()][msg.sender];

        if (existingOrder.isActive) {
            revert("Active limit order already exists");
        }
        

        // Transfer tokens from user to hook contract
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        ERC20 tokenContract = ERC20(Currency.unwrap(token));


        // Transfer the total amount (including fees) from user to hook
        tokenContract.transferFrom(msg.sender, address(this), totalAmount);

        limitOrders[key.toId()][msg.sender] = LimitOrder({
            user: msg.sender,
            amount: baseAmount, // Store original amount without fees
            totalAmount: totalAmount, // Store total amount including fees
            oraclePrice: oraclePrice,
            tolerance: tolerance,
            zeroForOne: zeroForOne,
            isActive: true,
            tokensTransferred: true // Set to true since we've already transferred tokens
        });

        emit LimitOrderPlaced(
            key.toId(),
            msg.sender,
            baseAmount,
            oraclePrice,
            tolerance
        );
    }

    function _executeLimitOrder(
        PoolKey memory key,
        LimitOrder storage order
    ) internal {

        // Calculate the actual amount we can swap (base amount without fees)
        uint256 swapAmount = order.amount;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: int256(swapAmount), // Use base amount for swap
            sqrtPriceLimitX96: order.zeroForOne
                ? TickMath.getSqrtPriceAtTick(-1)
                : TickMath.getSqrtPriceAtTick(1)
        });

        // Execute the swap - the pool manager will take the tokens it needs during the swap
        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
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

        emit LimitOrderExecuted(key.toId(), order.user, order.amount, 0);
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

        emit LimitOrderPlaced(
            poolId,
            msg.sender,
            newAmount,
            order.oraclePrice,
            newTolerance
        );
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

    
    function calculateOrderAmounts(uint256 amount, PoolKey calldata key) external pure returns (uint256 baseAmount, uint256 totalAmount) {
        uint256 poolFee = key.fee;
        uint256 fee = (amount * poolFee) / 10000;
        baseAmount = amount;
        totalAmount = amount + fee;
        return (baseAmount, totalAmount);
    }
}

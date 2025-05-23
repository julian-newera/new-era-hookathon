// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================
// Imports
// =============================================
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IExtsload} from "v4-core/src/interfaces/IExtsload.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import "forge-std/console.sol";
import {TWAMMHelper} from "./libraries/TWAMMHelper.sol";
import {ITWAMM} from "../src/interfaces/ITWAMM.sol";
import {TwammMath} from "../src/libraries/TWAMM/TwammMath.sol";
import {OrderPool} from "../src/libraries/TWAMM/OrderPool.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";

// =============================================
// Contract Definition
// =============================================
contract NewEraHook is BaseHook, ITWAMM {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using OrderPool for OrderPool.State;

    // =============================================
    // Events
    // =============================================
    event LimitOrderPlaced(
        PoolId poolId,
        address user,
        uint256 orderId,
        uint256 amount,
        uint256 oraclePrice,
        uint256 tolerance
    );
    event LimitOrderExecuted(
        PoolId poolId,
        address user,
        uint256 orderId,
        uint256 amount,
        uint256 executionPrice
    );
    event LimitOrderCancelled(PoolId poolId, address user, uint256 orderId, uint256 amount);

    // =============================================
    // Structs
    // =============================================
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

    // TWAMM State
    struct State {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => Order) orders;
        mapping(bytes32 => OrderKey) orderKeys;
    }

    struct PoolParamsOnExecute {
        uint160 sqrtPriceX96;
        uint128 liquidity;
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

    // =============================================
    // Storage & State Variables
    // =============================================
    mapping(PoolId => mapping(address => mapping(uint256 => LimitOrder))) public limitOrders;
    mapping(PoolId => mapping(address => uint256)) public userOrderCount;
    mapping(PoolId => State) internal twammStates;
    mapping(PoolId => address) public poolAddresses;
    mapping(Currency => mapping(address => uint256)) public tokensOwed;

    address public immutable admin;
    IPriceOracle public immutable priceOracle;

    // =============================================
    // Constants
    // =============================================
    uint256 constant MAX_ORDERS_PER_USER = 60;
    int256 internal constant MIN_DELTA = -1;
    bool internal constant ZERO_FOR_ONE = true;
    bool internal constant ONE_FOR_ZERO = false;

    // =============================================
    // Errors
    // =============================================
    error InvalidTolerance();
    error NoActiveLimitOrder();
    error UnauthorizedCaller();
    error InvalidAmount();
    error PriceAboveLimit();
    error LimitOrderConditionsNotMet();
    error TooManyOrders();
    error OnlyAdmin();
    error InsufficientFunds();
    // error InvalidPriceOrLiquidity();

    // =============================================
    // Constructor
    // =============================================
    constructor(
        IPoolManager _poolManager,
        address _priceOracle
    ) BaseHook(_poolManager) {
        priceOracle = IPriceOracle(_priceOracle);
        admin = msg.sender;
    }

    // =============================================
    // Core Hook Functions
    // =============================================
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
                beforeAddLiquidity: true,
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
        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];
    
         // one-time initialization enforced in PoolManager
        initialize(_getTWAMM(key));

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
        executeTWAMMOrders(key);

        if (sender == address(this)) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        address orderOwner = abi.decode(hookData, (address));
        PoolId poolId = key.toId();
        uint256 orderCount = userOrderCount[poolId][orderOwner];

        uint256 i = 0;
        while (i < orderCount) {
            LimitOrder storage order = limitOrders[poolId][orderOwner][i];
            if (!order.isActive) {
                i++;
                continue;
            }

            uint160 sqrtPriceX96 = params.sqrtPriceLimitX96;
            uint256 currentPrice = (uint256(sqrtPriceX96) *
                uint256(sqrtPriceX96) *
                1e18) >> 192;

            uint256 latestOraclePrice = priceOracle.getLatestPrice(
                ERC20(Currency.unwrap(key.currency1)).name()
            );
            order.oraclePrice = latestOraclePrice; // Update the order with latest price
            
            // Scale oracle price to match pool price scale (1e18)
            uint256 scaledOraclePrice = (latestOraclePrice * 1e18) / 100;
            
            bool shouldExecute = true;
            if (order.tolerance > 0) {
                uint256 scaledTolerance = (order.tolerance * 1e18) / 10000;
                uint256 priceLimit = order.zeroForOne
                    ? scaledOraclePrice - scaledTolerance // For sell orders
                    : scaledOraclePrice + scaledTolerance; // For buy orders

                shouldExecute = (order.zeroForOne && currentPrice <= priceLimit) ||
                    (!order.zeroForOne && currentPrice >= priceLimit);
            }

            if (shouldExecute) {
                _executeLimitOrder(key, order);
                // Set isActive to false after execution
                order.isActive = false;
                emit LimitOrderExecuted(poolId, orderOwner, i, order.amount, currentPrice);
            }
            i++;
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        address orderOwner = abi.decode(hookData, (address));
        PoolId poolId = key.toId();
        uint256 orderCount = userOrderCount[poolId][orderOwner];

        uint160 sqrtPriceX96 = params.sqrtPriceLimitX96;
        uint256 currentPrice = (uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96) *
            1e18) >> 192;

        uint256 latestOraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );
        
        uint256 scaledOraclePrice = (latestOraclePrice * 1e18) / 100;

        uint256 i = 0;
        while (i < orderCount) {
            LimitOrder storage order = limitOrders[poolId][orderOwner][i];
            if (!order.isActive) {
                i++;
                continue;
            }

            bool shouldExecute = true;
            if (order.tolerance > 0) {
                uint256 scaledTolerance = (order.tolerance * 1e18) / 10000;
                uint256 priceLimit = order.zeroForOne
                    ? scaledOraclePrice - scaledTolerance
                    : scaledOraclePrice + scaledTolerance;

                shouldExecute = (order.zeroForOne && currentPrice <= priceLimit) ||
                    (!order.zeroForOne && currentPrice >= priceLimit);
            }

            if (shouldExecute) {
                _executeLimitOrder(key, order);
                order.isActive = false;
                emit LimitOrderExecuted(poolId, orderOwner, i, order.amount, currentPrice);
            }
            i++;
        }
        return (this.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        executeTWAMMOrders(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    // =============================================
    // Limit Order Functions
    // =============================================
    function placeLimitOrder(
        PoolKey calldata key,
        uint256 baseAmount,
        uint256 totalAmount,
        uint256 tolerance,
        bool zeroForOne
    ) external {
        if (baseAmount == 0) revert InvalidAmount();
        if (tolerance > 10_000) revert InvalidTolerance(); // calculated in base points

        PoolId poolId = key.toId();
        
        // Check if user has reached maximum orders
        if (userOrderCount[poolId][msg.sender] >= MAX_ORDERS_PER_USER) {
            revert TooManyOrders();
        }

        // Get oracle price
        uint256 oraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );

        // Transfer tokens from user to hook contract
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        ERC20 tokenContract = ERC20(Currency.unwrap(token));

        // Transfer the total amount (including fees) from user to hook
        tokenContract.transferFrom(msg.sender, address(this), totalAmount);

        uint256 orderId = userOrderCount[poolId][msg.sender];

        limitOrders[poolId][msg.sender][orderId] = LimitOrder({
            user: msg.sender,
            amount: baseAmount, // Store original amount without fees
            totalAmount: totalAmount, // Store total amount including fees
            oraclePrice: oraclePrice,
            tolerance: tolerance,
            zeroForOne: zeroForOne,
            isActive: true,
            tokensTransferred: true // Set to true since we've already transferred tokens
        });

        // Increment order count for this user
        userOrderCount[poolId][msg.sender]++;

        emit LimitOrderPlaced(
            poolId,
            msg.sender,
            orderId,
            baseAmount,
            oraclePrice,
            tolerance
        );
    }

    function _executeLimitOrder(
        PoolKey memory key,
        LimitOrder storage order
    ) internal {
        uint256 swapAmount = order.amount;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: int256(swapAmount),
            sqrtPriceLimitX96: order.zeroForOne
                ? TickMath.getSqrtPriceAtTick(-1)
                : TickMath.getSqrtPriceAtTick(1)
        });

        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
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

        emit LimitOrderExecuted(key.toId(), order.user, 0, order.amount, 0);
    }

    function updateLimitOrder(
        PoolKey calldata key,
        address orderOwner,
        uint256 orderId,
        uint256 newAmount,
        uint256 newTolerance
    ) external {
        PoolId poolId = key.toId();
        LimitOrder storage order = limitOrders[poolId][orderOwner][orderId];

        if (order.user == address(0)) revert NoActiveLimitOrder();
        if (order.user != msg.sender) revert UnauthorizedCaller();
        if (!order.isActive) revert NoActiveLimitOrder();
        if (newTolerance > 10000) revert InvalidTolerance(); // Max 100% in basis points
        if (newAmount == 0) revert InvalidAmount();

        uint256 poolFee = key.fee;
        uint256 fee = (newAmount * poolFee) / 10000;
        uint256 newTotalAmount = newAmount + fee;

        order.amount = newAmount;
        order.totalAmount = newTotalAmount;
        order.tolerance = newTolerance;

        emit LimitOrderPlaced(
            poolId,
            msg.sender,
            orderId,
            newAmount,
            order.oraclePrice,
            newTolerance
        );
    }

    function cancelLimitOrder(
        PoolKey calldata key,
        address orderOwner,
        uint256 orderId
    ) external {
        PoolId poolId = key.toId();
        LimitOrder storage order = limitOrders[poolId][orderOwner][orderId];

        if (order.user == address(0)) revert NoActiveLimitOrder();
        if (order.user != msg.sender) revert UnauthorizedCaller();
        if (!order.isActive) revert NoActiveLimitOrder();

        // Return tokens to user if they were transferred
        if (order.tokensTransferred) {
            Currency token = order.zeroForOne ? key.currency0 : key.currency1;
            token.transfer(msg.sender, order.totalAmount);
        }

        delete limitOrders[poolId][orderOwner][orderId];

        emit LimitOrderCancelled(poolId, msg.sender, orderId, order.amount);
    }

    // =============================================
    // TWAMM Order Functions
    // =============================================
    /**
     * @notice Submits a new TWAMM order to the pool
     * @param key The pool key identifying the trading pair
     * @param orderKey The order key containing owner, expiration and direction
     * @param amountIn The total amount of tokens to be sold over the duration
     * @param expirationInterval The interval at which orders expire
     * @param tolerance The price tolerance for execution (in basis points)
     * @return orderId The unique identifier for the submitted order
     */
    function submitTWAMMOrder(
        PoolKey calldata key, 
        OrderKey memory orderKey, 
        uint256 amountIn, 
        uint256 expirationInterval,
        uint256 tolerance
    ) external returns (bytes32 orderId) {
        // Log order parameters for debugging
        console.log("submitTWAMMOrder - amountIn:", amountIn);
        console.log("submitTWAMMOrder - expirationInterval:", expirationInterval);
        console.log("submitTWAMMOrder - tolerance:", tolerance);
        
        // Validate tolerance is within acceptable range (max 100%)
        if (tolerance > 10_000) revert InvalidTolerance();

        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];
        
        // Execute any pending orders before submitting new one
        executeTWAMMOrders(key);

        // Calculate duration and sell rate
        uint256 duration = orderKey.expiration - block.timestamp;
        console.log("submitTWAMMOrder - duration:", duration);
        uint256 sellRate = amountIn / duration; // Rate at which tokens will be sold
        console.log("submitTWAMMOrder - calculated sellRate:", sellRate);
        
        // Submit the order to the TWAMM state
        orderId = _submitTWAMMOrder(twamm, orderKey, sellRate, expirationInterval, tolerance);
        
        // Transfer tokens from user to contract
        Currency token = orderKey.zeroForOne ? key.currency0 : key.currency1;
        ERC20 tokenContract = ERC20(Currency.unwrap(token));
        console.log("submitTWAMMOrder - transferring tokens:", amountIn);
        tokenContract.transferFrom(msg.sender, address(this), amountIn);

        // Emit event with order details
        emit SubmitOrder(
            poolId,
            orderKey.owner,
            orderKey.expiration,
            orderKey.zeroForOne,
            sellRate,
            _getTWAMMOrder(twamm, orderKey).earningsFactorLast,
            tolerance
        );
    }

    function _submitTWAMMOrder(
        State storage self, 
        OrderKey memory orderKey, 
        uint256 sellRate, 
        uint256 expirationInterval,
        uint256 tolerance
    ) internal returns (bytes32 orderId) {
        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (self.lastVirtualOrderTimestamp == 0) revert NotInitialized();
        if (orderKey.expiration <= block.timestamp) revert ExpirationLessThanBlocktime(orderKey.expiration);
        if (sellRate == 0) revert SellRateCannotBeZero();
        if (orderKey.expiration % expirationInterval != 0) revert ExpirationNotOnInterval(orderKey.expiration);

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert OrderAlreadyExists(orderKey);

        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            orderPool.sellRateCurrent += sellRate;
            orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRate;
        }

        self.orders[orderId] = Order({
            sellRate: sellRate, 
            earningsFactorLast: orderPool.earningsFactorCurrent,
            tolerance: tolerance
        });
        
        self.orderKeys[orderId] = orderKey;
    }

    function updateTWAMMOrder(
        PoolKey memory key, 
        OrderKey memory orderKey, 
        int256 amountDelta,
        uint256 newExpiration,
        uint256 expirationInterval,
        uint256 newTolerance
    ) external returns (uint256 tokens0Owed, uint256 tokens1Owed) {
        if (newTolerance > 10_000) revert InvalidTolerance();

        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];

        executeTWAMMOrders(key);

        if (newExpiration != 0) {
            if (newExpiration <= block.timestamp) revert ExpirationLessThanBlocktime(newExpiration);
            if (newExpiration % expirationInterval != 0) revert ExpirationNotOnInterval(newExpiration);
            orderKey.expiration = newExpiration;
        }

        (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellrate, uint256 newEarningsFactorLast) =
            _updateTWAMMOrder(twamm, orderKey, amountDelta, expirationInterval, newTolerance);

        if (orderKey.zeroForOne) {
            tokens0Owed += sellTokensOwed;
            tokens1Owed += buyTokensOwed;
        } else {
            tokens0Owed += buyTokensOwed;
            tokens1Owed += sellTokensOwed;
        }

        tokensOwed[key.currency0][orderKey.owner] += tokens0Owed;
        tokensOwed[key.currency1][orderKey.owner] += tokens1Owed;

        if (amountDelta > 0) {
            Currency token = orderKey.zeroForOne ? key.currency0 : key.currency1;
            ERC20 tokenContract = ERC20(Currency.unwrap(token));
            tokenContract.transferFrom(msg.sender, address(this), uint256(amountDelta));
        }

        emit UpdateOrder(
            poolId, 
            orderKey.owner, 
            orderKey.expiration, 
            orderKey.zeroForOne, 
            newSellrate, 
            newEarningsFactorLast,
            newTolerance
        );
    }

    function _updateTWAMMOrder(
        State storage self, 
        OrderKey memory orderKey, 
        int256 amountDelta,
        uint256 expirationInterval,
        uint256 newTolerance
    ) internal returns (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 earningsFactorLast) {
        Order storage order = _getTWAMMOrder(self, orderKey);
        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (order.sellRate == 0) revert OrderDoesNotExist(orderKey);
        if (amountDelta != 0 && orderKey.expiration <= block.timestamp) revert CannotModifyCompletedOrder(orderKey);

        unchecked {
            earningsFactorLast = orderKey.expiration <= block.timestamp
                ? orderPool.earningsFactorAtInterval[orderKey.expiration]
                : orderPool.earningsFactorCurrent;
            buyTokensOwed =
                ((earningsFactorLast - order.earningsFactorLast) * order.sellRate) >> FixedPoint96.RESOLUTION;

            if (orderKey.expiration <= block.timestamp) {
                // Update order pool state
                orderPool.sellRateCurrent -= order.sellRate;
                orderPool.sellRateEndingAtInterval[orderKey.expiration] -= order.sellRate;
                
                // Set sell rate to 0 before deleting
                order.sellRate = 0;
                
                // Delete the expired order
                delete self.orders[_orderId(orderKey)];
            } else {
                order.earningsFactorLast = earningsFactorLast;
                if (newTolerance != 0) {
                    order.tolerance = newTolerance;
                }
            }

            if (amountDelta != 0) {
                uint256 duration = orderKey.expiration - block.timestamp;
                uint256 unsoldAmount = order.sellRate * duration;
                if (amountDelta == MIN_DELTA) amountDelta = -int256(unsoldAmount);
                int256 newSellAmount = int256(unsoldAmount) + amountDelta;
                if (newSellAmount < 0) revert InvalidAmountDelta(orderKey, unsoldAmount, amountDelta);

                newSellRate = uint256(newSellAmount) / duration;

                if (amountDelta < 0) {
                    uint256 sellRateDelta = order.sellRate - newSellRate;
                    orderPool.sellRateCurrent -= sellRateDelta;
                    orderPool.sellRateEndingAtInterval[orderKey.expiration] -= sellRateDelta;
                    sellTokensOwed = uint256(-amountDelta);
                } else {
                    uint256 sellRateDelta = newSellRate - order.sellRate;
                    orderPool.sellRateCurrent += sellRateDelta;
                    orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRateDelta;
                }
                if (newSellRate == 0) {
                    delete self.orders[_orderId(orderKey)];
                } else {
                    order.sellRate = newSellRate;
                }
            }
        }
    }

    function claimTWAMMTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred)
    {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];
        if (amountRequested != 0 && amountRequested < amountTransferred) amountTransferred = amountRequested;
        if (currentBalance < amountTransferred) amountTransferred = currentBalance;
        tokensOwed[token][msg.sender] -= amountTransferred;
        ERC20 tokenContract = ERC20(Currency.unwrap(token));
        tokenContract.transfer(to, amountTransferred);
    }

    /**
     * @notice Executes all pending TWAMM orders in the pool
     * @param key The pool key identifying the trading pair
     * @dev This function handles the execution of all pending orders, including:
     *      1. Price checks against oracle
     *      2. Order execution based on tolerance
     *      3. Token transfers and settlements
     */
    function executeTWAMMOrders(PoolKey memory key) public {
        PoolId poolId = key.toId();
        
        // Load current pool state
        bytes32 slot0 = poolManager.extsload(keccak256(abi.encode(poolId, 0)));
        uint160 sqrtPriceX96 = uint160(uint256(slot0));
        bytes32 slot1 = poolManager.extsload(keccak256(abi.encode(poolId, 1)));
        uint128 liquidity = uint128(uint256(slot1));
        State storage twamm = twammStates[poolId];

        // Validate pool initialization
        if (twamm.lastVirtualOrderTimestamp == 0) revert NotInitialized();

        // Get current price from oracle and calculate scaled price
        uint256 latestOraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );
        uint256 scaledOraclePrice = (latestOraclePrice * 1e18) / 100;
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;

        // Check if there are any active orders to execute
        if (twamm.orderPool0For1.sellRateCurrent > 0 || twamm.orderPool1For0.sellRateCurrent > 0) {
            // Create default order key for execution
            OrderKey memory orderKey = OrderKey({
                owner: address(this),
                expiration: block.timestamp + 3600, // 1 hour from now
                zeroForOne: true
            });

            // Get order tolerance and check if execution is allowed
            Order storage order = _getTWAMMOrder(twamm, orderKey);
            uint256 scaledTolerance = (order.tolerance * 1e18) / 10000;
            uint256 priceLimit = scaledOraclePrice + scaledTolerance;
            bool shouldExecute = currentPrice <= priceLimit;

            if (shouldExecute) {
                // Execute orders and get new price
                (bool zeroForOne, uint160 sqrtPriceLimitX96) =
                    _executeTWAMMOrders(twamm, poolManager, key, PoolParamsOnExecute(sqrtPriceX96, liquidity), orderKey);

                // If price changed, execute the swap
                if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
                    // Calculate swap amount limit to prevent overflows
                    int256 swapAmountLimit = -int256(zeroForOne ? key.currency0.balanceOfSelf() : key.currency1.balanceOfSelf());
                    poolManager.unlock(abi.encode(key, IPoolManager.SwapParams(zeroForOne, swapAmountLimit, sqrtPriceLimitX96)));
                }
            }
        }
    }

    /**
     * @notice Internal function to execute TWAMM orders and update pool state
     * @param self The TWAMM state
     * @param poolManager The pool manager contract
     * @param key The pool key
     * @param pool Current pool parameters
     * @param orderKey The order key for execution
     * @return zeroForOne Whether the swap is token0 for token1
     * @return newSqrtPriceX96 The new sqrt price after execution
     */
    function _executeTWAMMOrders(
        State storage self,
        IPoolManager poolManager,
        PoolKey memory key,
        PoolParamsOnExecute memory pool,
        OrderKey memory orderKey
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        // Check if there are any orders to execute
        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = block.timestamp;
            return (false, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
        
        // Calculate next expiration timestamp
        uint256 nextExpirationTimestamp = prevTimestamp + (orderKey.expiration - (prevTimestamp % orderKey.expiration));

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

        // Process all orders up to current timestamp
        unchecked {
            while (nextExpirationTimestamp <= block.timestamp) {
                // Check if there are orders expiring at this timestamp
                if (
                    orderPool0For1.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                        || orderPool1For0.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                ) {
                    // Execute orders based on pool state
                    if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                        // Both pools have orders
                        pool = _advanceToNewTimestamp(
                            self,
                            key,
                            AdvanceParams(
                                orderKey.expiration,
                                nextExpirationTimestamp,
                                nextExpirationTimestamp - prevTimestamp,
                                pool
                            )
                        );
                    } else {
                        // Only one pool has orders
                        pool = _advanceTimestampForSinglePoolSell(
                            self,
                            key,
                            AdvanceSingleParams(
                                orderKey.expiration,
                                nextExpirationTimestamp,
                                nextExpirationTimestamp - prevTimestamp,
                                pool,
                                orderPool0For1.sellRateCurrent != 0
                            )
                        );
                    }
                    prevTimestamp = nextExpirationTimestamp;
                }
                nextExpirationTimestamp += orderKey.expiration;

                if (!_hasOutstandingOrders(self)) break;
            }

            // Process remaining time if there are still orders
            if (prevTimestamp < block.timestamp && _hasOutstandingOrders(self)) {
                if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                    pool = _advanceToNewTimestamp(
                        self,
                        key,
                        AdvanceParams(orderKey.expiration, block.timestamp, block.timestamp - prevTimestamp, pool)
                    );
                } else {
                    pool = _advanceTimestampForSinglePoolSell(
                        self,
                        key,
                        AdvanceSingleParams(
                            orderKey.expiration,
                            block.timestamp,
                            block.timestamp - prevTimestamp,
                            pool,
                            orderPool0For1.sellRateCurrent != 0
                        )
                    );
                }
            }
        }

        // Update state and return results
        self.lastVirtualOrderTimestamp = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
    }

    /**
     * @notice Advances the pool state to a new timestamp, handling both order pools
     * @param self The TWAMM state
     * @param poolKey The pool key
     * @param params Parameters for the advancement including timestamps and pool state
     * @return Updated pool parameters after advancement
     */
    function _advanceToNewTimestamp(
        State storage self,
        PoolKey memory poolKey,
        AdvanceParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        uint160 finalSqrtPriceX96;
        // Convert seconds to Q96 format for precise calculations
        uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

        while (true) {
            // Calculate new price based on current state and elapsed time
            TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams(
                secondsElapsedX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                orderPool0For1.sellRateCurrent,
                orderPool1For0.sellRateCurrent
            );

            finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);

            // Check if we need to handle tick crossing
            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96);
            unchecked {
                if (crossingInitializedTick) {
                    // Handle tick crossing and update state
                    uint256 secondsUntilCrossingX96;
                    (params.pool, secondsUntilCrossingX96) = _advanceTimeThroughTickCrossing(
                        self, poolKey, TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool)
                    );
                    secondsElapsedX96 = secondsElapsedX96 - secondsUntilCrossingX96;
                } else {
                    // Calculate earnings updates for both pools
                    (uint256 earningsFactorPool0, uint256 earningsFactorPool1) =
                        TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

                    // Update pool states based on expiration interval
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

    /**
     * @notice Advances the pool state for a single pool's orders
     * @param self The TWAMM state
     * @param poolKey The pool key
     * @param params Parameters for the advancement
     * @return Updated pool parameters after advancement
     */
    function _advanceTimestampForSinglePoolSell(
        State storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        // Get the relevant order pool based on direction
        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
        uint256 totalEarnings;

        while (true) {
            // Calculate new price based on input amount
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );

            // Check if we need to handle tick crossing
            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96);

            if (crossingInitializedTick) {
                // Load tick data and handle liquidity changes
                bytes32 tickSlot = keccak256(abi.encode(poolKey.toId(), tick));
                bytes32 tickData = poolManager.extsload(tickSlot);
                int128 liquidityNetAtTick = int128(uint128(uint256(tickData)));

                uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(tick);

                // Calculate swap amounts for the tick crossing
                uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );
                uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );

                // Update liquidity and price
                if (params.zeroForOne) liquidityNetAtTick = -liquidityNetAtTick;
                params.pool.liquidity = LiquidityMath.addDelta(params.pool.liquidity, liquidityNetAtTick);
                params.pool.sqrtPriceX96 = initializedSqrtPrice;

                // Update earnings and remaining amount
                unchecked {
                    totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                // Calculate final earnings and update pool state
                if (params.zeroForOne) {
                    totalEarnings += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                }

                // Calculate and apply earnings factor
                uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / sellRateCurrent;

                // Update pool state based on expiration interval
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

    /**
     * @notice Handles the advancement of time through a tick crossing
     * @param self The TWAMM state
     * @param poolKey The pool key
     * @param params Parameters for the tick crossing
     * @return Updated pool parameters and seconds until crossing
     */
    function _advanceTimeThroughTickCrossing(
        State storage self,
        PoolKey memory poolKey,
        TickCrossingParams memory params
    ) private returns (PoolParamsOnExecute memory, uint256) {
        // Get the initialized price at the tick
        uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(params.initializedTick);

        // Calculate time needed to reach the tick
        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPrice,
            self.orderPool0For1.sellRateCurrent,
            self.orderPool1For0.sellRateCurrent
        );

        // Calculate earnings updates for both pools
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

        // Update pool states
        self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
        self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

        // Update liquidity and price
        unchecked {
            bytes32 tickSlot = keccak256(abi.encode(poolKey.toId(), params.initializedTick));
            bytes32 tickData = poolManager.extsload(tickSlot);
            int128 liquidityNet = int128(uint128(uint256(tickData)));
            if (initializedSqrtPrice < params.pool.sqrtPriceX96) liquidityNet = -liquidityNet;
            params.pool.liquidity = liquidityNet < 0
                ? params.pool.liquidity - uint128(-liquidityNet)
                : params.pool.liquidity + uint128(liquidityNet);

            params.pool.sqrtPriceX96 = initializedSqrtPrice;
        }
        return (params.pool, secondsUntilCrossingX96);
    }

    // =============================================
    // Helper Functions
    // =============================================

    /**
     * @notice Initializes the TWAMM state for a new pool
     * @param self The TWAMM state to initialize
     */
    function initialize(State storage self) internal {
        self.lastVirtualOrderTimestamp = block.timestamp;
    }

    /**
     * @notice Creates a new order key for TWAMM orders
     * @param owner The address of the order owner
     * @param expiration The timestamp when the order expires
     * @param zeroForOne Whether the order is selling token0 for token1
     * @return The created order key
     */
    function createOrderKey(
        address owner,
        uint256 expiration,
        bool zeroForOne
    ) external pure returns (OrderKey memory) {
        return OrderKey({
            owner: owner,
            expiration: expiration,
            zeroForOne: zeroForOne
        });
    }

    /**
     * @notice Settles a currency balance with the pool manager
     * @param currency The currency to settle
     * @param amount The amount to settle
     */
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /**
     * @notice Takes tokens from the pool manager
     * @param currency The currency to take
     * @param amount The amount to take
     */
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    /**
     * @notice Calculates the base amount and total amount (including fees) for an order
     * @param amount The base amount of the order
     * @param key The pool key containing fee information
     * @return baseAmount The original amount without fees
     * @return totalAmount The total amount including fees
     */
    function calculateOrderAmounts(uint256 amount, PoolKey calldata key) external pure returns (uint256 baseAmount, uint256 totalAmount) {
        uint256 poolFee = key.fee;
        uint256 fee = (amount * poolFee) / 10000;
        baseAmount = amount;
        totalAmount = amount + fee;
        return (baseAmount, totalAmount);
    }

    /**
     * @notice Allows the admin to withdraw funds from the contract
     * @param token The currency to withdraw
     * @dev Only callable by the admin address
     */
    function withdrawFunds(Currency token) external {
        if (msg.sender != admin) revert OnlyAdmin();

        uint256 balance = token.balanceOf(address(this));

        if (balance > 0) {
            token.transfer(admin, balance);
        }
    }

    /**
     * @notice Generates a unique order ID from an order key
     * @param key The order key to generate an ID from
     * @return The unique order ID
     */
    function _orderId(OrderKey memory key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /**
     * @notice Retrieves a TWAMM order from storage
     * @param self The TWAMM state
     * @param key The order key
     * @return The order data
     */
    function _getTWAMMOrder(State storage self, OrderKey memory key) internal view returns (Order storage) {
        return self.orders[_orderId(key)];
    }

    /**
     * @notice Gets the TWAMM state for a pool
     * @param key The pool key
     * @return The TWAMM state for the pool
     */
    function _getTWAMM(PoolKey memory key) private view returns (State storage) {
        return twammStates[PoolId.wrap(keccak256(abi.encode(key)))];
    }

    /**
     * @notice Checks if there are any outstanding orders in either pool
     * @param self The TWAMM state
     * @return True if there are outstanding orders, false otherwise
     */
    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }

    /**
     * @notice Retrieves an order key from its ID
     * @param self The TWAMM state
     * @param orderId The order ID
     * @return The order key
     */
    function _getOrderKeyFromId(State storage self, bytes32 orderId) internal view returns (OrderKey memory) {
        return self.orderKeys[orderId];
    }

    /**
     * @notice Checks if a price movement will cross an initialized tick
     * @param pool Current pool parameters
     * @param poolKey The pool key
     * @param nextSqrtPriceX96 The target sqrt price
     * @return crossingInitializedTick Whether a tick will be crossed
     * @return nextTickInit The next initialized tick
     */
    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        // Get current tick and target tick
        nextTickInit = TickMath.getTickAtSqrtPrice(pool.sqrtPriceX96);
        int24 targetTick = TickMath.getTickAtSqrtPrice(nextSqrtPriceX96);
        bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
        bool nextTickInitFurtherThanTarget = false;

        // Search for the next initialized tick
        while (!nextTickInitFurtherThanTarget) {
            unchecked {
                if (searchingLeft) nextTickInit -= 1;
            }
            
            // Load tick bitmap word
            int16 wordPos = int16(nextTickInit >> 8);
            bytes32 wordSlot = keccak256(abi.encode(poolKey.toId(), wordPos));
            bytes32 wordData = poolManager.extsload(wordSlot);
            
            // Check for initialized ticks in the word
            uint256 bitPos = uint256(uint24(nextTickInit % 256));
            uint256 mask = searchingLeft ? (1 << bitPos) - 1 : type(uint256).max << (bitPos + 1);
            uint256 maskedWord = uint256(wordData) & mask;
            
            if (maskedWord != 0) {
                // Found an initialized tick
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
                // Move to next word
                nextTickInit = searchingLeft ? 
                    int24(wordPos * 256 - 1) : 
                    int24((wordPos + 1) * 256);
            }
            
            // Check if we've gone past the target tick
            nextTickInitFurtherThanTarget = searchingLeft ? nextTickInit <= targetTick : nextTickInit > targetTick;
            if (crossingInitializedTick) break;
        }
        if (nextTickInitFurtherThanTarget) crossingInitializedTick = false;
    }

    function getTWAMMOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory) {
        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];
        return _getTWAMMOrder(twamm, orderKey);
    }

    function getTWAMMOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        State storage twamm = _getTWAMM(key);
        return zeroForOne
            ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
            : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
// Imports
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
import {TWAMMHelper} from "./libraries/TWAMMHelper.sol";
import {ITWAMM} from "../src/interfaces/ITWAMM.sol";
import {TwammMath} from "../src/libraries/TWAMM/TwammMath.sol";
import {OrderPool} from "../src/libraries/TWAMM/OrderPool.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LimitHelper} from "./libraries/LimitHelper.sol";
import {console} from "forge-std/console.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
// Contract Definition
contract NewEraHook is BaseHook, ITWAMM, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using OrderPool for OrderPool.State;
    using LimitHelper for *;

    enum UnlockType {
        Execute   
    }

    bytes internal constant ZERO_BYTES = bytes("");

    // Events
    event LimitOrderExecuted(
        PoolId poolId,
        address user,
        uint256 orderId,
        uint256 amount,
        uint256 executionPrice
    );
    event LimitOrderCancelled(PoolId poolId, address user, uint256 orderId, uint256 amount);
    // Structs
    struct LimitOrder {
        address user;
        uint256 amount;
        uint256 totalAmount;
        uint256 oraclePrice;
        uint256 oraclePrice2;
        uint256 tolerance;
        bool zeroForOne;
        bool isActive;
        bool tokensTransferred;
        uint256 creationTimestamp;
        bool shouldExecute;
    }
    // TWAMM State
    struct State {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => Order) orders;
        mapping(bytes32 => OrderKey) orderKeys;
        bytes32[] orderIds; // <-- add this
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
    // Storage & State Variables
    mapping(PoolId => mapping(address => mapping(uint256 => LimitOrder))) public limitOrders;
    mapping(PoolId => mapping(address => uint256)) public userOrderCount;
    mapping(PoolId => State) internal twammStates;
    mapping(PoolId => address) public poolAddresses;
    mapping(Currency => mapping(address => uint256)) public tokensOwed;
    PoolId[] public allPoolIds; // Track all pools
    address public immutable admin;
    IPriceOracle public immutable priceOracle;
    mapping(address => bytes32[]) private userTWAMMOrderIds;
    // Add user tracking for limit orders
    mapping(PoolId => address[]) public poolUsers;
    mapping(PoolId => mapping(address => bool)) public isPoolUser;
    // Constants
    int256 internal constant MIN_DELTA = -1;
    bool internal constant ZERO_FOR_ONE = true;
    bool internal constant ONE_FOR_ZERO = false;
    // Errors
    error NoActiveLimitOrder();
    error UnauthorizedCaller();
    error PriceAboveLimit();
    error LimitOrderConditionsNotMet();
    error OnlyAdmin();
    error InsufficientFunds();
    // Constructor
    constructor(
        IPoolManager _poolManager,
        address _priceOracle
    ) BaseHook(_poolManager) {
        priceOracle = IPriceOracle(_priceOracle);
        admin = msg.sender;
    }
    // Core Hook Functions
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
        initialize(_getTWAMM(key));
        poolAddresses[poolId] = address(
            uint160(uint256(keccak256(abi.encode(poolId))))
        );
        // Add to allPoolIds if not already present
        bool exists = false;
        for (uint256 i = 0; i < allPoolIds.length; i++) {
            if (PoolId.unwrap(allPoolIds[i]) == PoolId.unwrap(poolId)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            allPoolIds.push(poolId);
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // executeTWAMMOrders(key);
        // console.log("hello");
        if (sender == address(this)) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }
        PoolId poolId = key.toId();
        address[] storage users = poolUsers[poolId];
        for (uint256 u = 0; u < users.length; u++) {
            address orderOwner = users[u];
            uint256 orderCount = userOrderCount[poolId][orderOwner];
            uint256 i = 0;
            while (i < orderCount) {
                LimitOrder storage order = limitOrders[poolId][orderOwner][i];
                if (!order.isActive) {
                    i++;
                    continue;
                }
                // uint160 sqrtPriceX96 = params.sqrtPriceLimitX96;
                // (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
                // uint256 currentPrice = (uint256(sqrtPriceX96) *
                //     uint256(sqrtPriceX96) *
                //     1e18) >> 192;
                // uint256 latestOraclePrice = LimitHelper.getOraclePrice2(key, priceOracle);
                // order.oraclePrice = LimitHelper.getOraclePrice(key, priceOracle);
                // order.oraclePrice2 = LimitHelper.getOraclePrice2(key, priceOracle);
                // uint256 scaledOraclePrice = (latestOraclePrice * 1e18) / 100;
                
                // bool shouldExecute = true;
                // if (order.tolerance > 0) {
                //     uint256 scaledTolerance = (order.tolerance * 1e18) / 10000;
                //     uint256 priceLimit = order.zeroForOne
                //         ? scaledOraclePrice - scaledTolerance 
                //         : scaledOraclePrice + scaledTolerance; 
                //     shouldExecute = (order.zeroForOne && currentPrice <= priceLimit) ||
                //         (!order.zeroForOne && currentPrice >= priceLimit);
                // }
                // if (shouldExecute) {
                //     // _executeLimitOrder(key, order);
                //     // order.isActive = false;
                //     // emit LimitOrderExecuted(poolId, orderOwner, i, order.amount, currentPrice);
                // }
                i++;
            }
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // console.log("hello");
        if (sender == address(this)) {
            return (this.afterSwap.selector, 0);
        }
        PoolId poolId = key.toId();
        address[] storage users = poolUsers[poolId];
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        // uint160 sqrtPriceX96 = 4552702936290292383660862550846;
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        currentPrice = currentPrice * 1e18;
        uint256 latestOraclePrice = LimitHelper.getOraclePrice(key, priceOracle);
        uint256 scaledOraclePrice = (latestOraclePrice * 1e18) / 100;
        console.log("currentPrice", currentPrice);
        console.log("latestOraclePrice", latestOraclePrice);
        console.log("scaledOraclePrice", scaledOraclePrice);
        for (uint256 u = 0; u < users.length; u++) {
            address orderOwner = users[u];
            uint256 orderCount = userOrderCount[poolId][orderOwner];
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
                    // _executeLimitOrder(key, order);
                    order.shouldExecute = true;
                    emit LimitOrderExecuted(poolId, orderOwner, i, order.amount, currentPrice);
                }
                i++;
            }
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

    function unlockCallback(bytes calldata rawData) external virtual returns (bytes memory) {
        (UnlockType initialOpType) = abi.decode(rawData[:32], (UnlockType));
        if (initialOpType == UnlockType.Execute) {
            (UnlockType opType, PoolKey memory key, IPoolManager.SwapParams memory swapParams, address orderOwner) = abi.decode(rawData, (UnlockType, PoolKey, IPoolManager.SwapParams, address));
            PoolId poolId = key.toId();
            uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
            console.log("liquidity", swapParams.amountSpecified);
            console.log("liquidity", liquidity);
            console.log(orderOwner);
            // console.log(key.currency0.balanceOf(address(this)));
            console.log(key.currency1.balanceOf(address(this)));
            BalanceDelta delta = poolManager.swap(key, swapParams, ZERO_BYTES);
            console.log(delta.amount0());
            console.log(delta.amount1());
            if (swapParams.zeroForOne) {
                if (delta.amount0() < 0) {
                    _settle(key.currency0, uint128(-delta.amount0()));
                }
                if (delta.amount1() > 0) {
                    _take(key.currency1, uint128(delta.amount1()));
                    key.currency1.transfer(address(orderOwner), uint128(delta.amount1()));
                }
            } else {
                if (delta.amount1() < 0) {
                    _settle(key.currency1, uint128(-delta.amount1()));
                }
                if (delta.amount0() > 0) {
                    _take(key.currency0, uint128(delta.amount0()));
                    key.currency0.transfer(address(orderOwner), uint128(delta.amount0()));
                }
            }
            console.log(delta.amount0());
            console.log(delta.amount1());
            console.log(key.currency0.balanceOf(address(this)));
            console.log(key.currency1.balanceOf(address(this)));
            console.log("GG");
            return bytes("");
        }
    }

    function executeLimitOrders(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        address[] storage users = poolUsers[poolId];
        for (uint256 u = 0; u < users.length; u++) {
            address orderOwner = users[u];
            uint256 orderCount = userOrderCount[poolId][orderOwner];
            uint256 i = 0;
            while (i < orderCount) {
                LimitOrder storage order = limitOrders[poolId][orderOwner][i];
                if (!order.isActive) {
                    i++;
                    continue;
                }
                if (order.shouldExecute) {
                    uint256 swapAmount = order.amount;
                    poolManager.unlock(abi.encode(UnlockType.Execute, key, IPoolManager.SwapParams(order.zeroForOne, -1*int256(swapAmount) , TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE), orderOwner));
                    order.shouldExecute = false;
                    order.isActive = false;
                }
                i++;
            }
        }
    }

    // Limit Order Functions
    function placeLimitOrder(
        PoolKey calldata key,
        uint256 baseAmount,
        uint256 totalAmount,
        uint256 tolerance,
        bool zeroForOne
    ) external {
        PoolId poolId = key.toId();
        LimitHelper.validateLimitOrder(
            baseAmount,
            tolerance,
            userOrderCount[poolId][msg.sender]
        );
        uint256 oraclePrice = LimitHelper.getOraclePrice(key, priceOracle);
        uint256 oraclePrice2 = LimitHelper.getOraclePrice2(key, priceOracle);
        LimitHelper.transferTokens(key, totalAmount, zeroForOne, msg.sender);
        uint256 orderId = userOrderCount[poolId][msg.sender];
        limitOrders[poolId][msg.sender][orderId] = LimitOrder({
            user: msg.sender,
            amount: baseAmount, 
            totalAmount: totalAmount,
            oraclePrice: oraclePrice,
            oraclePrice2: oraclePrice2,
            tolerance: tolerance,
            zeroForOne: zeroForOne,
            isActive: true,
            tokensTransferred: true,
            creationTimestamp: block.timestamp,
            shouldExecute: false
        });
        userOrderCount[poolId][msg.sender]++;
        // Track user for this pool if not already tracked
        if (!isPoolUser[poolId][msg.sender]) {
            poolUsers[poolId].push(msg.sender);
            isPoolUser[poolId][msg.sender] = true;
        }
        LimitHelper.emitLimitOrderPlaced(
            poolId,
            msg.sender,
            orderId,
            baseAmount,
            oraclePrice,
            tolerance
        );
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
        if (newTolerance > 10000) revert LimitHelper.InvalidTolerance();
        if (newAmount == 0) revert LimitHelper.InvalidAmount();
        uint256 poolFee = key.fee;
        uint256 fee = (newAmount * poolFee) / 10000;
        uint256 newTotalAmount = newAmount + fee;
        order.amount = newAmount;
        order.totalAmount = newTotalAmount;
        order.tolerance = newTolerance;
        LimitHelper.emitLimitOrderPlaced(
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
        if (order.tokensTransferred) {
            Currency token = order.zeroForOne ? key.currency0 : key.currency1;
            token.transfer(msg.sender, order.totalAmount);
        }
        delete limitOrders[poolId][orderOwner][orderId];
        emit LimitOrderCancelled(poolId, msg.sender, orderId, order.amount);
    }
    // TWAMM Order Functions
    function submitTWAMMOrder(
        PoolKey calldata key, 
        OrderKey memory orderKey, 
        uint256 amountIn, 
        uint256 expirationInterval,
        uint256 tolerance
    ) external returns (bytes32 orderId) {
        if (tolerance > 10_000) revert LimitHelper.InvalidTolerance();
        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];
        executeTWAMMOrders(key);
        uint256 duration = orderKey.expiration - block.timestamp;
        uint256 sellRate = amountIn / duration;
        orderId = _submitTWAMMOrder(twamm, orderKey, sellRate, expirationInterval, tolerance);
        Currency token = orderKey.zeroForOne ? key.currency0 : key.currency1;
        ERC20 tokenContract = ERC20(Currency.unwrap(token));
        tokenContract.transferFrom(msg.sender, address(this), amountIn);
        userTWAMMOrderIds[msg.sender].push(orderId);
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
        self.orderIds.push(orderId); // <-- add this
    }

    function updateTWAMMOrder(
        PoolKey memory key, 
        OrderKey memory orderKey, 
        int256 amountDelta,
        uint256 newExpiration,
        uint256 expirationInterval,
        uint256 newTolerance
    ) external returns (uint256 tokens0Owed, uint256 tokens1Owed) {
        if (newTolerance > 10_000) revert LimitHelper.InvalidTolerance();
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
                orderPool.sellRateCurrent -= order.sellRate;
                orderPool.sellRateEndingAtInterval[orderKey.expiration] -= order.sellRate;
                order.sellRate = 0;
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
    function executeTWAMMOrders(PoolKey memory key) public {
        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        if (twamm.lastVirtualOrderTimestamp == 0) revert NotInitialized();
        // Iterate over all orders in twamm.orders
        for (uint256 i = 0; i < twamm.orderIds.length; i++) {
            bytes32 orderId = twamm.orderIds[i];
            OrderKey memory orderKey = twamm.orderKeys[orderId];
            (bool zeroForOne, uint160 sqrtPriceLimitX96) =
                _executeTWAMMOrders(twamm, poolManager, key, PoolParamsOnExecute(sqrtPriceX96, liquidity), orderKey);
            if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
                uint256 sellRate = zeroForOne ? twamm.orderPool0For1.sellRateCurrent : twamm.orderPool1For0.sellRateCurrent;
                uint256 timeElapsed = block.timestamp - twamm.lastVirtualOrderTimestamp;
                int256 swapAmount = int256(sellRate * timeElapsed);
                BalanceDelta delta = poolManager.swap(
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: swapAmount,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
                    }),
                    ""
                );
                if (zeroForOne) {
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
                if (zeroForOne) {
                    tokensOwed[key.currency1][orderKey.owner] += uint256(uint128(delta.amount1()));
                } else {
                    tokensOwed[key.currency0][orderKey.owner] += uint256(uint128(delta.amount0()));
                }
            }
        }
    }
    
    function _executeTWAMMOrders(
        State storage self,
        IPoolManager poolManager,
        PoolKey memory key,
        PoolParamsOnExecute memory pool,
        OrderKey memory orderKey
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = block.timestamp;
            return (false, 0);
        }
        uint256 latestOraclePrice = priceOracle.getLatestPrice(
            ERC20(Currency.unwrap(key.currency1)).name()
        );
        uint256 scaledOraclePrice = (latestOraclePrice * 1e18) / 100;
        uint256 currentPrice;
        unchecked {
            currentPrice = (uint256(pool.sqrtPriceX96) * uint256(pool.sqrtPriceX96) * 1e18) >> 192;
        }
        Order storage order = _getTWAMMOrder(self, orderKey);
        uint256 scaledTolerance = (order.tolerance * 1e18) / 10000;
        uint256 priceLimit = scaledOraclePrice + scaledTolerance;
        bool shouldExecute = currentPrice <= priceLimit;
        console.log("currentPrice:", currentPrice);
        console.log("priceLimit:", priceLimit);
        console.log("shouldExecute:", shouldExecute);
        if (!shouldExecute) {
            return (false, 0);
        }
        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
        console.log("prevTimestamp:", prevTimestamp);
        console.log("orderKey.expiration:", orderKey.expiration);
        uint256 mod = prevTimestamp % orderKey.expiration;
        console.log("mod:", mod);
        if (orderKey.expiration < mod) {
            console.log("ERROR: orderKey.expiration < mod, will underflow!");
        }
        uint256 nextExpirationTimestamp;
        if (mod == 0) {
            nextExpirationTimestamp = prevTimestamp + orderKey.expiration;
        } else {
            nextExpirationTimestamp = prevTimestamp + (orderKey.expiration - mod);
        }
        console.log("LOOP: nextExpirationTimestamp:", nextExpirationTimestamp);
        console.log("LOOP: prevTimestamp:", prevTimestamp);
        console.log("LOOP: block.timestamp:", block.timestamp);
        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;
        unchecked {
            while (nextExpirationTimestamp <= block.timestamp) {
                console.log("testr", nextExpirationTimestamp, block.timestamp);
                if (
                    orderPool0For1.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                        || orderPool1For0.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                ) {
                    if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
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
                console.log("LOOP: updated prevTimestamp:", prevTimestamp);
                console.log("LOOP: updated nextExpirationTimestamp:", nextExpirationTimestamp);

                if (!_hasOutstandingOrders(self)) break;
            }
            if (prevTimestamp < block.timestamp && _hasOutstandingOrders(self)) {
                console.log("Outstanding", orderPool0For1.sellRateCurrent, orderPool1For0.sellRateCurrent);
                if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                    pool = _advanceToNewTimestamp(
                        self,
                        key,
                        AdvanceParams(orderKey.expiration, block.timestamp, block.timestamp - prevTimestamp, pool)
                    );
                } else {
        console.log("Outstanding2");
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
        self.lastVirtualOrderTimestamp = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
    }
    function _advanceToNewTimestamp(
        State storage self,
        PoolKey memory poolKey,
        AdvanceParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        TWAMMHelper.PoolParamsOnExecute memory newPool = TWAMMHelper._advanceToNewTimestamp(self.orderPool0For1, self.orderPool1For0, poolKey, TWAMMHelper.AdvanceParams(params.expirationInterval, params.nextTimestamp, params.secondsElapsed, TWAMMHelper.PoolParamsOnExecute(params.pool.sqrtPriceX96, params.pool.liquidity)), poolManager);
        return(PoolParamsOnExecute(newPool.sqrtPriceX96, newPool.liquidity));
    }
    function _advanceTimestampForSinglePoolSell(
        State storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        TWAMMHelper.PoolParamsOnExecute memory newPool = TWAMMHelper._advanceTimestampForSinglePoolSell(self.orderPool0For1, self.orderPool1For0, poolKey, TWAMMHelper.AdvanceSingleParams(params.expirationInterval, params.nextTimestamp, params.secondsElapsed, TWAMMHelper.PoolParamsOnExecute(params.pool.sqrtPriceX96, params.pool.liquidity), params.zeroForOne), poolManager);
        return(PoolParamsOnExecute(newPool.sqrtPriceX96, newPool.liquidity));
    }
    function _advanceTimeThroughTickCrossing(
        State storage self,
        PoolKey memory poolKey,
        TickCrossingParams memory params
    ) private returns (PoolParamsOnExecute memory, uint256) {
        (TWAMMHelper.PoolParamsOnExecute memory newPool, uint256 secondsUntilCrossingX96) = TWAMMHelper._advanceTimeThroughTickCrossing(self.orderPool0For1, self.orderPool1For0 , poolKey, TWAMMHelper.TickCrossingParams(params.initializedTick, params.nextTimestamp, params.secondsElapsedX96, TWAMMHelper.PoolParamsOnExecute(params.pool.sqrtPriceX96, params.pool.liquidity)), poolManager);
        return(PoolParamsOnExecute(newPool.sqrtPriceX96, newPool.liquidity), secondsUntilCrossingX96);
    }
    // Helper Functions
    function initialize(State storage self) internal {
        self.lastVirtualOrderTimestamp = block.timestamp;
    }
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
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
    function calculateOrderAmounts(uint256 amount, PoolKey calldata key) external pure returns (uint256 baseAmount, uint256 totalAmount) {
        return TWAMMHelper.calculateOrderAmounts(amount, key);
    }
    function withdrawFunds(Currency token) external {
        if (msg.sender != admin) revert OnlyAdmin();
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.transfer(admin, balance);
        }
    }
    function _orderId(OrderKey memory key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
    function _getTWAMMOrder(State storage self, OrderKey memory key) internal view returns (Order storage) {
        return self.orders[_orderId(key)];
    }
    function _getTWAMM(PoolKey memory key) private view returns (State storage) {
        return twammStates[PoolId.wrap(keccak256(abi.encode(key)))];
    }
    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }
    function _getOrderKeyFromId(State storage self, bytes32 orderId) internal view returns (OrderKey memory) {
        return self.orderKeys[orderId];
    }
    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        return TWAMMHelper._isCrossingInitializedTick(TWAMMHelper.PoolParamsOnExecute(pool.sqrtPriceX96, pool.liquidity), poolKey, nextSqrtPriceX96, poolManager);
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
    /**
     * @notice Returns all limit orders (active and inactive) for the caller across all pools
     * @return orders An array of LimitOrder structs
     */
    function getUserLimitOrders() external view returns (LimitOrder[] memory orders) {
        uint256 totalOrders = 0;
        // First, count total orders for allocation
        for (uint256 p = 0; p < allPoolIds.length; p++) {
            PoolId poolId = allPoolIds[p];
            totalOrders += userOrderCount[poolId][msg.sender];
        }
        orders = new LimitOrder[](totalOrders);
        uint256 idx = 0;
        for (uint256 p = 0; p < allPoolIds.length; p++) {
            PoolId poolId = allPoolIds[p];
            uint256 orderCount = userOrderCount[poolId][msg.sender];
            for (uint256 i = 0; i < orderCount; i++) {
                orders[idx] = limitOrders[poolId][msg.sender][i];
                idx++;
            }
        }
    }
    function getUserTWAMMOrders() external view returns (Order[] memory orders, OrderKey[] memory orderKeys) {
        bytes32[] storage ids = userTWAMMOrderIds[msg.sender];
        orders = new Order[](ids.length);
        orderKeys = new OrderKey[](ids.length);
        uint256 found = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 p = 0; p < allPoolIds.length; p++) {
                State storage twamm = twammStates[allPoolIds[p]];
                if (twamm.orders[ids[i]].sellRate != 0) {
                    orders[found] = twamm.orders[ids[i]];
                    orderKeys[found] = twamm.orderKeys[ids[i]];
                    found++;
                    break;
                }
            }
        }
        // Resize arrays to found count
        assembly { mstore(orders, found) mstore(orderKeys, found) }
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IAvsLogic} from "./interfaces/IAvsLogic.sol";
import {IAttestationCenter} from "./interfaces/IAttestationCenter.sol";
import {console} from "forge-std/console.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {ITWAMM} from "./interfaces/ITWAMM.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {TwammMath} from "./libraries/TWAMM/TwammMath.sol";
import {OrderPool} from "./libraries/TWAMM/OrderPool.sol";
import {PoolGetters} from "./libraries/PoolGetters.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {PricingHelper} from "./libraries/PricingHelper.sol";
import {Epoch, EpochLibrary, EpochHelper} from "./libraries/EpochHelper.sol";
import {TWAMMHelper} from "./libraries/TWAMMHelper.sol";
import {TWAMMCalculator} from "./libraries/TWAMMCalculator.sol";
import {OrderHandler} from "./libraries/OrderHandler.sol";
import {EpochHandler} from "./libraries/EpochHandler.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract NewEraHook is IAvsLogic, BaseHook, ITWAMM, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using EpochLibrary for Epoch;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    
    using TransferHelper for IERC20Minimal;
    using OrderPool for OrderPool.State;
    using TickMath for int24;
    using TickMath for uint160;
    using SafeCast for uint256;
    using PoolGetters for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);
    using TWAMMHelper for TWAMMHelper.State;

    enum UnlockType {
        Place,    
        Withdraw, 
        Fill,
        Other    
    }

    int256 internal constant MIN_DELTA = -1;
    bool internal constant ZERO_FOR_ONE = true;
    bool internal constant ONE_FOR_ZERO = false;

    uint256 public immutable expirationInterval;

    mapping(PoolId => TWAMMHelper.State) internal twammStates;

    mapping(Currency => mapping(address => uint256)) public tokensOwed;

    error ZeroLiquidity();
    error InRange();
    error CrossedRange();
    error Filled();
    error NotFilled();
    error NotPoolManagerToken();
    error OnlyAttestationCenter();
    error ExecutionPriceTooHigh();
    
    address public immutable ATTESTATION_CENTER;
    
    mapping(bytes32 => uint256) public tokenPrices;

    event PriceUpdated(address indexed base, address indexed quote, uint256 price);

    event Place(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    event Fill(Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne);

    event Kill(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    event Withdraw(address indexed owner, Epoch indexed epoch, uint128 liquidity);

    bytes internal constant ZERO_BYTES = bytes("");

    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);

    mapping(PoolId => int24) public tickLowerLasts;
    Epoch public epochNext = Epoch.wrap(1);

    mapping(bytes32 => Epoch) public epochs;
    mapping(Epoch => EpochHelper.EpochInfo) public epochInfos;

    constructor(address _attestationCenterAddress, IPoolManager _poolManager, uint256 _expirationInterval) 
        BaseHook(_poolManager)
    {
        ATTESTATION_CENTER = _attestationCenterAddress;
        expirationInterval = _expirationInterval;
    }

    function afterTaskSubmission(
        IAttestationCenter.TaskInfo calldata _taskInfo,
        bool _isApproved,
        bytes calldata, /* _tpSignature */
        uint256[2] calldata, /* _taSignature */
        uint256[] calldata /* _operatorIds */
    ) external {
        if (msg.sender != ATTESTATION_CENTER) revert OnlyAttestationCenter();

        (address base, address quote, uint256 price) = abi.decode(
            _taskInfo.data,
            (address, address, uint256)
        );

        if (_isApproved) {
            bytes32 key = keccak256(abi.encodePacked(base, quote));
            tokenPrices[key] = price;
            emit PriceUpdated(base, quote, price);
        }
    }

    function beforeTaskSubmission(
        IAttestationCenter.TaskInfo calldata _taskInfo,
        bool _isApproved,
        bytes calldata _tpSignature,
        uint256[2] calldata _taSignature,
        uint256[] calldata _attestersIds
    ) external {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
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

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata
    )
        internal
        virtual
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {

        executeTWAMMOrders(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function priceToTick(uint256 _price, int24 tickSpacing) internal pure returns (int24) {
        return PricingHelper.priceToTick(_price, tickSpacing);
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    )
        internal
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));
        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(key.toId(), key.tickSpacing);
        if (lower > upper) return (BaseHook.afterSwap.selector, 0);

        bool zeroForOne = !params.zeroForOne;
        for (; lower <= upper; lower += key.tickSpacing) {
            _fillEpoch(key, lower, zeroForOne);
        }

        setTickLowerLast(key.toId(), tickLower);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        return PricingHelper._sqrt(x);
    }

    function getTickLowerLast(PoolId poolId) public view returns (int24) {
        return tickLowerLasts[poolId];
    }

    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne) public view returns (Epoch) {
        return epochs[EpochHelper.getEpochKey(key, tickLower, zeroForOne)];
    }

    function setEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne, Epoch epoch) private {
        epochs[EpochHelper.getEpochKey(key, tickLower, zeroForOne)] = epoch;
    }

    function getEpochLiquidity(Epoch epoch, address owner) external view returns (uint256) {
        return epochInfos[epoch].liquidity[owner];
    }

    function getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        return EpochHelper.getTickLower(tick, tickSpacing);
    }

    function _fillEpoch(PoolKey calldata key, int24 lower, bool zeroForOne) internal {
        EpochHandler.processFill(key, lower, zeroForOne, getEpoch(key, lower, zeroForOne), 
            epochs, epochInfos, poolManager);
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = getTickLower(getTick(poolId), tickSpacing);
        int24 tickLowerLast = getTickLowerLast(poolId);

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    function _unlockCallbackFill(PoolKey calldata key, int24 tickLower, int256 liquidityDelta)
        internal
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        // Initialize the calculation state
        Epoch epoch = getEpoch(key, tickLower, ZERO_FOR_ONE);
        bool isZeroForOne = ZERO_FOR_ONE;
        EpochHelper.EpochInfo storage epochInfo = epochInfos[epoch];
        
        TWAMMCalculator.CalculationState memory state = TWAMMCalculator.initializeCalculation(
            key, tickLower, isZeroForOne, epochInfo.liquidityTotal, 
            epochInfo.token0Total, epochInfo.token1Total, poolManager
        );

        // Calculate TWAMM amounts
        (state.token0PerLiquidity, state.token1PerLiquidity) = TWAMMCalculator.calculateOrderAmounts(
            state, 0, block.timestamp - expirationInterval, block.timestamp
        );
        
        // Apply the liquidity modification
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

        // Calculate token amounts
        token0Amount = uint256(uint128(delta.amount0()));
        token1Amount = uint256(uint128(delta.amount1()));

        // Add calculated TWAMM amounts
        token0Amount += state.token0PerLiquidity * uint256(uint128(epochInfo.liquidityTotal)) / 1e18;
        token1Amount += state.token1PerLiquidity * uint256(uint128(epochInfo.liquidityTotal)) / 1e18;
    }

    function place(PoolKey calldata key, int24 tickLower, bool zeroForOne, uint128 liquidity) external {
        if (liquidity == 0) revert ZeroLiquidity();

        if(tickLower == 0) {
            (address baseToken, address quoteToken) = zeroForOne ? 
            (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)) :
            (Currency.unwrap(key.currency1), Currency.unwrap(key.currency0));

            bytes32 pairKey = keccak256(abi.encodePacked(baseToken, quoteToken));
            uint256 storedPrice = tokenPrices[pairKey];

            if (storedPrice > 0) {
                (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
                
                uint256 expectedPrice = zeroForOne ? storedPrice : 1e36 / storedPrice;
                uint256 sqrtExpectedPrice = _sqrt(expectedPrice);
                uint160 expectedSqrtPriceX96 = uint160((sqrtExpectedPrice * (1 << 96)) / 1e9);

                bool isInvalidPrice = zeroForOne ?
                    currentSqrtPriceX96 < (expectedSqrtPriceX96 * 99) / 100 :
                    currentSqrtPriceX96 > (expectedSqrtPriceX96 * 101) / 100;

                if (isInvalidPrice) {
                    this.place(key, priceToTick(storedPrice, key.tickSpacing), zeroForOne, liquidity);
                    return;
                }else{
                    uint160 MIN_SQRT_PRICE_LIMIT = 4295128739;
                    uint160 MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342;
                    IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: int256(uint256(liquidity)),
                        sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
                    });
                    poolManager.swap(key, swapParams, ZERO_BYTES);
                    return;
                }
            }
        }

        poolManager.unlock(
            abi.encode(UnlockType.Place, key, tickLower, zeroForOne, int256(uint256(liquidity)), msg.sender)
        );

        EpochHandler.processPlace(key, tickLower, zeroForOne, msg.sender, liquidity, epochNext, epochs, epochInfos, poolManager);
    }

    function unlockCallback(bytes calldata rawData) external virtual returns (bytes memory) {
        (UnlockType opType) = abi.decode(rawData[:32], (UnlockType));
        if (opType == UnlockType.Place) {
            (UnlockType opType,
            PoolKey memory key,
            int24 tickLower,
            bool zeroForOne,
            int256 liquidityDelta,
            address owner) = abi.decode(rawData, (UnlockType, PoolKey, int24, bool, int256, address));
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

            return new bytes(0);
        }
        if (opType == UnlockType.Other) {
            (UnlockType opType, PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (UnlockType, PoolKey, IPoolManager.SwapParams));

            BalanceDelta delta = poolManager.swap(key, swapParams, ZERO_BYTES);

            if (swapParams.zeroForOne) {
                if (delta.amount0() < 0) {
                    key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
                }
                if (delta.amount1() > 0) {
                    key.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())), false);
                }
            } else {
                if (delta.amount1() < 0) {
                    key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
                }
                if (delta.amount0() > 0) {
                    key.currency0.take(poolManager, address(this), uint256(uint128(delta.amount0())), false);
                }
            }
            return bytes("");
        }
    }

    function kill(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to) external {
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        OrderHandler.processKill(key, tickLower, zeroForOne, to, epoch, epochInfos, poolManager);
    }

    function withdraw(Epoch epoch, address to) external returns (uint256 amount0, uint256 amount1) {
        return EpochHandler.processWithdraw(epoch, to, msg.sender, epochInfos, poolManager);
    }

    function unlockCallbackWithdraw(
        Currency currency0,
        Currency currency1,
        uint256 token0Amount,
        uint256 token1Amount,
        address to
    ) external selfOnly {
        if (token0Amount > 0) {
            poolManager.burn(address(this), currency0.toId(), token0Amount);
            poolManager.take(currency0, to, token0Amount);
        }
        if (token1Amount > 0) {
            poolManager.burn(address(this), currency1.toId(), token1Amount);
            poolManager.take(currency1, to, token1Amount);
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManagerToken();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    modifier onlyValidPools(address hooks) {
        require(hooks != address(0), "Invalid pool hooks");
        _;
    }

    modifier selfOnly() {
        require(msg.sender == address(this), "Caller must be self");
        _;
    }

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    )
        internal
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        initialize(_getTWAMM(key));
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4) {
        executeTWAMMOrders(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256) {
        return twammStates[key].lastVirtualOrderTimestamp;
    }

    function getOrder(PoolKey calldata poolKey, OrderKey calldata orderKey) external view returns (Order memory) {
        return _getOrder(twammStates[PoolId.wrap(keccak256(abi.encode(poolKey)))], orderKey);
    }

    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        TWAMMHelper.State storage twamm = _getTWAMM(key);
        return zeroForOne
            ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
            : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
    }

    /// @notice Initialize TWAMM state
    function initialize(TWAMMHelper.State storage self) internal {
        self.lastVirtualOrderTimestamp = block.timestamp;
    }

    function executeTWAMMOrders(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        TWAMMHelper.State storage twamm = twammStates[poolId];
        if (twamm.lastVirtualOrderTimestamp == 0) revert NotInitialized();

        (bool zeroForOne, uint160 sqrtPriceLimitX96) =
            twamm._executeTWAMMOrders(poolManager, key, TWAMMHelper.PoolParamsOnExecute(sqrtPriceX96, poolManager.getLiquidity(poolId)), expirationInterval);

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
            int256 swapAmountLimit = -int256(zeroForOne ? key.currency0.balanceOfSelf() : key.currency1.balanceOfSelf());
            poolManager.unlock(abi.encode(UnlockType.Other, key, IPoolManager.SwapParams(zeroForOne, swapAmountLimit, sqrtPriceLimitX96)));
        }
    }

    function submitOrder(PoolKey calldata key, OrderKey memory orderKey, uint256 amountIn)
        external
        returns (bytes32 orderId)
    {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        TWAMMHelper.State storage twamm = twammStates[poolId];
        executeTWAMMOrders(key);

        uint256 sellRate;
        unchecked {
            uint256 duration = orderKey.expiration - block.timestamp;
            sellRate = amountIn / duration;
            orderId = _submitOrder(twamm, orderKey, sellRate);
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), sellRate * duration);
        }

        emit SubmitOrder(
            poolId,
            orderKey.owner,
            orderKey.expiration,
            orderKey.zeroForOne,
            sellRate,
            TWAMMHelper._getOrder(twamm, orderKey).earningsFactorLast
        );
    }

    function _submitOrder(TWAMMHelper.State storage self, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (bytes32 orderId)
    {
        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (self.lastVirtualOrderTimestamp == 0) revert NotInitialized();
        if (orderKey.expiration <= block.timestamp) revert ExpirationLessThanBlocktime(orderKey.expiration);
        if (sellRate == 0) revert SellRateCannotBeZero();
        if (orderKey.expiration % expirationInterval != 0) revert ExpirationNotOnInterval(orderKey.expiration);

        orderId = TWAMMHelper._orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert OrderAlreadyExists(orderKey);

        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            orderPool.sellRateCurrent += sellRate;
            orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRate;
        }

        self.orders[orderId] = Order({sellRate: sellRate, earningsFactorLast: orderPool.earningsFactorCurrent});
    }

    function updateOrder(PoolKey memory key, OrderKey memory orderKey, int256 amountDelta)
        external
        returns (uint256 tokens0Owed, uint256 tokens1Owed)
    {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        TWAMMHelper.State storage twamm = twammStates[poolId];

        executeTWAMMOrders(key);

        (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellrate, uint256 newEarningsFactorLast) =
            _updateOrder(twamm, orderKey, amountDelta);

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
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), uint256(amountDelta));
        }

        emit UpdateOrder(
            poolId, orderKey.owner, orderKey.expiration, orderKey.zeroForOne, newSellrate, newEarningsFactorLast
        );
    }

    function _updateOrder(TWAMMHelper.State storage self, OrderKey memory orderKey, int256 amountDelta)
        internal
        returns (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 earningsFactorLast)
    {
        Order storage order = TWAMMHelper._getOrder(self, orderKey);
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
                delete self.orders[TWAMMHelper._orderId(orderKey)];
            } else {
                order.earningsFactorLast = earningsFactorLast;
            }

            if (amountDelta != 0) {
                uint256 duration = orderKey.expiration - block.timestamp;
                uint256 unsoldAmount = order.sellRate * duration;
                if (amountDelta == MIN_DELTA) amountDelta = -(unsoldAmount.toInt256());
                int256 newSellAmount = unsoldAmount.toInt256() + amountDelta;
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
                    delete self.orders[TWAMMHelper._orderId(orderKey)];
                } else {
                    order.sellRate = newSellRate;
                }
            }
        }
    }

    function claimTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred)
    {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];
        if (amountRequested != 0 && amountRequested < amountTransferred) amountTransferred = amountRequested;
        if (currentBalance < amountTransferred) amountTransferred = currentBalance; // to catch precision errors
        tokensOwed[token][msg.sender] -= amountTransferred;
        IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountTransferred);
    }

    function _getTWAMM(PoolKey memory key) private view returns (TWAMMHelper.State storage) {
        return twammStates[PoolId.wrap(keccak256(abi.encode(key)))];
    }

    function _executeTWAMMOrders(
        TWAMMHelper.State storage self,
        IPoolManager manager,
        PoolKey memory key,
        TWAMMHelper.PoolParamsOnExecute memory pool
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        return self._executeTWAMMOrders(manager, key, pool, expirationInterval);
    }

    function _advanceToNewTimestamp(TWAMMHelper.State storage self, PoolKey memory poolKey, TWAMMHelper.AdvanceParams memory params)
        private
        returns (TWAMMHelper.PoolParamsOnExecute memory)
    {
        return self._advanceToNewTimestamp(poolKey, params, poolManager);
    }

    function _advanceTimestampForSinglePoolSell(
        TWAMMHelper.State storage self,
        PoolKey memory poolKey,
        TWAMMHelper.AdvanceSingleParams memory params
    ) private returns (TWAMMHelper.PoolParamsOnExecute memory) {
        return self._advanceTimestampForSinglePoolSell(poolKey, params, poolManager);
    }

    function _advanceTimeThroughTickCrossing(
        TWAMMHelper.State storage self,
        PoolKey memory poolKey,
        TWAMMHelper.TickCrossingParams memory params
    ) private returns (TWAMMHelper.PoolParamsOnExecute memory, uint256) {
        return self._advanceTimeThroughTickCrossing(poolKey, params, poolManager);
    }


    function _isCrossingInitializedTick(
        TWAMMHelper.PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        return TWAMMHelper._isCrossingInitializedTick(pool, poolKey, nextSqrtPriceX96, poolManager);
    }

    function _getOrder(TWAMMHelper.State storage self, OrderKey memory key) internal view returns (Order storage) {
        return self.orders[TWAMMHelper._orderId(key)];
    }

    function _hasOutstandingOrders(TWAMMHelper.State storage self) internal view returns (bool) {
        return TWAMMHelper._hasOutstandingOrders(self);
    }
}

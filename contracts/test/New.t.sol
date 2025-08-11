// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {console} from "forge-std/console.sol";
import {LimitHelper} from "../src/libraries/LimitHelper.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {NewEraHook} from "../src/Hook.sol";

contract CounterTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    TestERC20 token0; // First token in the pair
    TestERC20 token1; // Second token in the pair

    PriceOracle priceOracle;
    PoolSwapTest router;

    NewEraHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address user = address(0x123);

    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, recipient);
        params[3] = abi.encode(poolKey.currency1, recipient);

        return (actions, params);
    }

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifacts();

        (currency0, currency1) = deployCurrencyPair();
        // deployMintAndApprove2Currencies();

        router = new PoolSwapTest(poolManager);
        priceOracle = new PriceOracle();
        string[] memory assets = new string[](1);
        assets[0] = "TEST";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 100;
        priceOracle.updatePrices(assets, prices);

        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));


        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        // Deploy hook contract
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            address(priceOracle)
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(NewEraHook).creationCode,
            constructorArgs
        );
        hook = new NewEraHook{salt: salt}(
            IPoolManager(address(poolManager)),
            address(priceOracle)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        // tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        // tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        uint160 startingPrice = 4552702936290292383660862550846;
        int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        tickLower = ((currentTick - 750 * 60) / 60) * 60;
        tickUpper = ((currentTick + 750 * 60) / 60) * 60;

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount,
            liquidityAmount
        );

        // slippage limits
        uint256 amount0Max = liquidityAmount + 1;
        uint256 amount1Max = liquidityAmount + 1;

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), Constants.ZERO_BYTES
        );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // Initialize Pool
        params[0] = abi.encodeWithSelector(positionManager.initializePool.selector, poolKey, startingPrice, Constants.ZERO_BYTES);

        // Mint Liquidity
        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 3600
        );

        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        positionManager.multicall{value: valueToPass}(params);

        // int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        // tickLower = ((currentTick - 750 * 60) / 60) * 60;
        // tickUpper = ((currentTick + 750 * 60) / 60) * 60;

        // (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
        //     startingPrice,
        //     TickMath.getSqrtPriceAtTick(tickLower),
        //     TickMath.getSqrtPriceAtTick(tickUpper),
        //     liquidityAmount
        // );

        // console.log("ggg", amount0Expected, amount1Expected);

        // (tokenId,) = positionManager.mint(
        //     poolKey,
        //     tickLower,
        //     tickUpper,
        //     liquidityAmount,
        //     amount0Expected + 1,
        //     amount1Expected + 1,
        //     address(this),
        //     block.timestamp,
        //     Constants.ZERO_BYTES
        // );
        console.log("ggg2");
    }

    // function testCounterHooks() public {
    //     // positions were created in setup()
    //     assertEq(hook.beforeAddLiquidityCount(poolId), 1);
    //     assertEq(hook.beforeRemoveLiquidityCount(poolId), 0);

    //     assertEq(hook.beforeSwapCount(poolId), 0);
    //     assertEq(hook.afterSwapCount(poolId), 0);

    //     // Perform a test swap //
    //     uint256 amountIn = 1e18;
    //     BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
    //         amountIn: amountIn,
    //         amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
    //         zeroForOne: true,
    //         poolKey: poolKey,
    //         hookData: Constants.ZERO_BYTES,
    //         receiver: address(this),
    //         deadline: block.timestamp + 1
    //     });
    //     // ------------------- //

    //     assertEq(int256(swapDelta.amount0()), -int256(amountIn));

    //     assertEq(hook.beforeSwapCount(poolId), 1);
    //     assertEq(hook.afterSwapCount(poolId), 1);
    // }

    // function testLiquidityHooks() public {
    //     // positions were created in setup()
    //     assertEq(hook.beforeAddLiquidityCount(poolId), 1);
    //     assertEq(hook.beforeRemoveLiquidityCount(poolId), 0);

    //     // remove liquidity
    //     uint256 liquidityToRemove = 1e18;
    //     positionManager.decreaseLiquidity(
    //         tokenId,
    //         liquidityToRemove,
    //         0, // Max slippage, token0
    //         0, // Max slippage, token1
    //         address(this),
    //         block.timestamp,
    //         Constants.ZERO_BYTES
    //     );

    //     assertEq(hook.beforeAddLiquidityCount(poolId), 1);
    //     assertEq(hook.beforeRemoveLiquidityCount(poolId), 1);
    // }

    function test_limitOrderExecution2() public {
        vm.startPrank(user);
        // Set up order parameters
        uint256 amount = 1e18;
        uint256 tolerance = 100; // 1% tolerance in basis points
        bool zeroForOne = false; // Buy order (token1 for token0)
        
        // Prepare tokens for the order
        token0.mint(user, amount * 2);
        token1.mint(user, amount * 2);

        console.log("before: ", token0.balanceOf(user));
        console.log("before: ", token1.balanceOf(user));
        token0.approve(address(hook), type(uint256).max);
        // token0.approve(address(router), type(uint256).max);
        // token1.approve(address(router), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        // token0.approve(address(poolManager), type(uint256).max);
        // token1.approve(address(poolManager), type(uint256).max);

        // Calculate order amounts including fees
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            amount,
            poolKey
        );

        // Get current oracle price

        // Prepare tokens for the buy order
        // token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(poolManager), totalAmount);

        // Additional approval for pool manager
        // token1.approve(address(manager), totalAmount);

        // Place the limit order
        hook.placeLimitOrder(
            poolKey,
            baseAmount,
            totalAmount,
            tolerance,
            zeroForOne
        );

        console.log("test2");
        // Verify order was created correctly
        (
            address orderUser,
            uint256 orderAmount,
            uint256 orderTotalAmount,
            uint256 oraclePrice,
            uint256 oraclePrice2,
            uint256 orderTolerance,
            bool orderZeroForOne,
            bool isActive,
            bool tokensTransferred,
            uint256 creationTimestamp,
            bool shouldExecute
        ) = hook.limitOrders(poolKey.toId(), user, 0);
        assertTrue(isActive, "Limit order should be created and active");
        assertFalse(orderZeroForOne, "Should be a buy order");
        assertEq(orderTotalAmount, totalAmount, "Total amount should match");
        assertEq(orderTolerance, tolerance, "Tolerance should match");
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(poolKey, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

            // Calculate price levels for the test
        uint160 initialSqrtPrice = TickMath.getSqrtPriceAtTick(0);
        uint256 initialPrice = (uint256(initialSqrtPrice) *
            uint256(initialSqrtPrice) *
            1e18) >> 192;
        uint160 targetSqrtPrice = TickMath.getSqrtPriceAtTick(1000);
        uint256 targetPrice = (uint256(targetSqrtPrice) *
            uint256(targetSqrtPrice) *
            1e18) >> 192;

        // Create swap parameters to move price up
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, // Swap direction to increase price
            amountSpecified: 1e18, // Large amount to ensure price movement
            sqrtPriceLimitX96: targetSqrtPrice // Target price 1000 ticks higher
        });
        console.log("test2");
        // Execute swap to trigger order execution
        // bytes memory hookData = abi.encode(user);
        vm.stopPrank();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        vm.startPrank(user);
        // router.swap(
        //     poolKey,
        //     params,
        //     PoolSwapTest.TestSettings({
        //         takeClaims: true,
        //         settleUsingBurn: false
        //     }),
        //     Constants.ZERO_BYTES
        // );

        console.log("test3");
        // Verify order was executed
        (, , , , , , , bool finalIsActive, , , bool finalShouldExecute ) = hook.limitOrders(
            poolKey.toId(),
            user,
            0
        );
        assertTrue(
            finalShouldExecute,
            "Limit order should be executed and inactive"
        );

        hook.executeLimitOrders(poolKey);

        console.log("aftrer: ", token0.balanceOf(user));
        console.log("aftrer: ", token1.balanceOf(user));

        vm.stopPrank();

    }
}

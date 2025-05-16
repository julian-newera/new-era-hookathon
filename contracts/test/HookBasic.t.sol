// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {NewEraHook} from "../src/Hook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IExtsload} from "v4-core/src/interfaces/IExtsload.sol";

// Import events from NewEraHook
event LimitOrderPlaced(
    PoolId poolId,
    address user,
    uint256 amount,
    uint256 oraclePrice,
    uint256 tolerance
);

contract NewEraHookBasicTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    NewEraHook hook;
    PriceOracle priceOracle;
    PoolId poolId;
    TestERC20 token0;
    TestERC20 token1;
    address user = address(0x123);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        // Deploy and set up price oracle
        priceOracle = new PriceOracle();
        string[] memory assets = new string[](1);
        assets[0] = "TEST";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 100;
        priceOracle.updatePrices(assets, prices);
        
        // Set up hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );
        
        // Deploy hook with correct constructor args
        bytes memory constructorArgs = abi.encode(address(manager), address(priceOracle));
        
        // Mine for a valid hook address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(NewEraHook).creationCode,
            constructorArgs
        );

        // Deploy hook with same salt to ensure address matches
        hook = new NewEraHook{salt: salt}(IPoolManager(address(manager)), address(priceOracle));
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Initialize pool
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 500, TickMath.getSqrtPriceAtTick(0));

        // Add initial liquidity
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -1000,
            tickUpper: 1000,
            liquidityDelta: 1e12,
            salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(key, params, "");

        // Mint and approve tokens for user
        vm.startPrank(user);
        token0.mint(user, 1000e18);
        token1.mint(user, 1000e18);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        // Approve hook to spend tokens on behalf of pool manager
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
    }

    function test_placeLimitOrder() public {
        vm.startPrank(user);
        
        uint256 tolerance = 100; // 1%
        bool zeroForOne = true;

        uint256 amount = 100; // Base amount in wei
       


        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(amount, key);
    

        // Place limit order
        hook.placeOrder(key, baseAmount, totalAmount, tolerance, zeroForOne);

        // Approve hook's tokens to pool manager
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        
        // Verify order was created
        (address orderUser, uint256 orderAmount, uint256 orderTotalAmount, uint256 oraclePrice, uint256 orderTolerance, bool orderZeroForOne, bool isActive, bool tokensTransferred) = 
            hook.limitOrders(key.toId(), user, 0);
        
        assertEq(orderUser, user, "Incorrect order user");
        assertEq(orderAmount, amount, "Incorrect order amount");
        assertEq(orderTolerance, tolerance, "Incorrect tolerance");
        assertEq(orderZeroForOne, zeroForOne, "Incorrect zeroForOne");
        assertTrue(isActive, "Order should be active");
        assertTrue(tokensTransferred, "Tokens should be transferred");
        
        vm.stopPrank();
    }

    function test_limitOrderExecution() public {
        vm.startPrank(user);
        
        uint256 amount = 200;
        uint256 tolerance = 100 / 100; // 1%
        bool zeroForOne = false; // Buy order
        
        // Calculate amounts using the new function
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(amount, key);
        
        console.log("Test setup:");
        console.log("Initial amount:", amount);
        console.log("Calculated base amount:", baseAmount);
        console.log("Calculated total amount:", totalAmount);
        
        // First, let's check the oracle price
        uint256 oraclePrice = priceOracle.getLatestPrice("TEST");
        console.log("Oracle Price:", oraclePrice);
        
        // Mint enough tokens for both amount and fees (only token1 since it's a buy order)
        token1.mint(user, totalAmount);
        console.log("Minted tokens:", totalAmount);
        console.log("User token balance after mint:", token1.balanceOf(user));
        
        // Approve the total amount for both hook and pool manager (only token1)
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);
        console.log("Approved amounts:");
        console.log("Hook allowance:", token1.allowance(user, address(hook)));
        console.log("Manager allowance:", token1.allowance(user, address(manager)));
        
        // Also approve the hook to spend tokens on behalf of the pool manager
        vm.stopPrank();
        token1.approve(address(manager), totalAmount);
        vm.startPrank(user);
        
        // Pass both base and total amounts to placeOrder
        hook.placeOrder(key, baseAmount, totalAmount, tolerance, zeroForOne);
        
        // Verify order was created
        (address orderUser, uint256 orderAmount, uint256 orderTotalAmount, uint256 orderOraclePrice, uint256 orderTolerance, bool orderZeroForOne, bool isActive, bool tokensTransferred) = 
            hook.limitOrders(key.toId(), user, 0);
        assertTrue(isActive, "Limit order should be created and active");
        assertFalse(orderZeroForOne, "Should be a buy order");
        assertEq(orderTotalAmount, totalAmount, "Total amount should match");
        assertEq(orderTolerance, tolerance, "Tolerance should match");

        vm.stopPrank();

        // Calculate initial sqrt price
        uint160 initialSqrtPrice = TickMath.getSqrtPriceAtTick(0);
        uint256 initialPrice = (uint256(initialSqrtPrice) * uint256(initialSqrtPrice) * 1e18) >> 192;
        console.log("Initial Price:", initialPrice);

        // Calculate target sqrt price - move up by 1000 ticks for a more significant price change
        uint160 targetSqrtPrice = TickMath.getSqrtPriceAtTick(1000);
        uint256 targetPrice = (uint256(targetSqrtPrice) * uint256(targetSqrtPrice) * 1e18) >> 192;
        console.log("Target Price:", targetPrice);

        // Move price up to be higher than oracle price + tolerance
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, // Swap in the direction that will move price up
            amountSpecified: 1e18, // Increased from 1e15 to 1e18
            sqrtPriceLimitX96: targetSqrtPrice // Move price up by 1000 ticks
        });

        // Execute swap through router (as any address)
        bytes memory hookData = abi.encode(user); // Pass user address as hookData

        swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            hookData
        );

        // Verify order was executed by the hook's automatic check
        (,,,,,, bool finalIsActive,) = hook.limitOrders(key.toId(), user, 0);
        assertFalse(finalIsActive, "Limit order should be executed and inactive");
    }

    function test_afterSwapOrderExecution() public {
        vm.startPrank(user);
        
        // Place two orders with different tolerances
        uint256 amount1 = 100;
        uint256 amount2 = 200;
        uint256 tolerance1 = 50; // 0.5%
        uint256 tolerance2 = 100; // 1%
        bool zeroForOne = false; // Buy orders
        
        // Calculate amounts for first order
        (uint256 baseAmount1, uint256 totalAmount1) = hook.calculateOrderAmounts(amount1, key);
        token1.mint(user, totalAmount1);
        token1.approve(address(hook), totalAmount1);
        token1.approve(address(manager), totalAmount1);
        
        // Place first order
        hook.placeOrder(key, baseAmount1, totalAmount1, tolerance1, zeroForOne);
        
        // Calculate amounts for second order
        (uint256 baseAmount2, uint256 totalAmount2) = hook.calculateOrderAmounts(amount2, key);
        token1.mint(user, totalAmount2);
        token1.approve(address(hook), totalAmount2);
        token1.approve(address(manager), totalAmount2);
        
        // Place second order
        hook.placeOrder(key, baseAmount2, totalAmount2, tolerance2, zeroForOne);
        
        vm.stopPrank();

        // Move price up significantly to trigger both orders
        uint160 targetSqrtPrice = TickMath.getSqrtPriceAtTick(2000); // Move price up by 2000 ticks
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: targetSqrtPrice
        });

        // Execute swap through router
        bytes memory hookData = abi.encode(user);
        swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            hookData
        );

        // Verify both orders were executed
        (,,,,,, bool isActive1,) = hook.limitOrders(key.toId(), user, 0);
        (,,,,,, bool isActive2,) = hook.limitOrders(key.toId(), user, 1);
        
        assertFalse(isActive1, "First order should be executed");
        assertFalse(isActive2, "Second order should be executed");
    }

    // function test_limitOrderUpdate() public {
    //     // Arrange
    //     uint256 amountIn = 1e18;
    //     uint256 tolerance = 5;
        
    //     vm.startPrank(user);
    //     token0.mint(user, amountIn);
    //     token0.approve(address(hook), amountIn);
        
    //     // Place initial order
    //     hook.placeOrder(key, amountIn, tolerance, true);
        
    //     // Act: Update order
    //     uint256 newAmount = 2e18;
    //     uint256 newTolerance = 10;
    //     hook.updateLimitOrder(key, newAmount, newTolerance);
        
    //     // Assert: Order should be updated
    //     (address orderUser, uint256 amount, uint256 oraclePrice, uint256 storedTolerance, bool zeroForOne, bool isActive,) =
    //         hook.limitOrders(key.toId(), user);
    //     assertEq(amount, newAmount, "Amount should be updated");
    //     assertEq(storedTolerance, newTolerance, "Tolerance should be updated");
    //     assertTrue(isActive, "Order should still be active");
        
    //     vm.stopPrank();
    // }

    // function test_limitOrderCancel() public {
    //     // Arrange
    //     uint256 amountIn = 1e18;
    //     uint256 tolerance = 5;
        
    //     vm.startPrank(user);
    //     token0.mint(user, amountIn);
    //     token0.approve(address(hook), amountIn);
        
    //     // Place order
    //     hook.placeOrder(key, amountIn, tolerance, true);
        
    //     // Record initial balance
    //     uint256 initialBalance = token0.balanceOf(user);
        
    //     // Act: Cancel order
    //     hook.cancelLimitOrder(key);
        
    //     // Assert: Order should be inactive and tokens returned
    //     (,,,,, bool isActive,) = hook.limitOrders(key.toId(), user);
    //     assertFalse(isActive, "Order should be inactive after cancellation");
    //     assertEq(token0.balanceOf(user), initialBalance + amountIn, "Tokens should be returned");
        
    //     vm.stopPrank();
    // }

    // function testFail_placeOrderZeroAmount() public {
    //     vm.startPrank(user);
    //     hook.placeOrder(key, 0, 5, true);
    //     vm.stopPrank();
    // }

    // function testFail_placeOrderInvalidTolerance() public {
    //     vm.startPrank(user);
    //     hook.placeOrder(key, 1e18, 10001, true); // > 100%
    //     vm.stopPrank();
    // }

    // function testFail_placeOrderDuplicate() public {
    //     vm.startPrank(user);
    //     uint256 amountIn = 1e18;
    //     token0.mint(user, amountIn);
    //     token0.approve(address(hook), amountIn);
        
    //     // Place first order
    //     hook.placeOrder(key, amountIn, 5, true);
        
    //     // Try to place second order
    //     hook.placeOrder(key, amountIn, 5, true);
        
    //     vm.stopPrank();
    // }

    // function testFail_updateOrderUnauthorized() public {
    //     // Place order as user
    //     vm.startPrank(user);
    //     hook.placeOrder(key, 1e18, 5, true);
    //     vm.stopPrank();

    //     // Try to update from different address
    //     vm.prank(address(0x456));
    //     hook.updateLimitOrder(key, 2e18, 10);
    // }
} 
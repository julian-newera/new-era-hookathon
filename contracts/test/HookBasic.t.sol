// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Import test utilities and core contracts
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
import {ITWAMM} from "../src/interfaces/ITWAMM.sol";
import {HookEnabledSwapRouter} from "../utils/HookEnabledSwapRouter.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {console} from "forge-std/console.sol";
import {LimitHelper} from "../src/libraries/LimitHelper.sol";

// Import events from NewEraHook for testing
event LimitOrderPlaced(
    PoolId poolId,
    address user,
    uint256 amount,
    uint256 oraclePrice,
    uint256 tolerance
);

/**
 * @title NewEraHookBasicTest
 * @notice Test suite for the NewEraHook contract, covering limit orders and TWAMM functionality
 * @dev Inherits from Test and Deployers to access testing utilities and deployment helpers
 */
contract NewEraHookBasicTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    // Contract instances
    NewEraHook hook; // Main hook contract
    PriceOracle priceOracle; // Price oracle for limit orders
    PoolId poolId; // Pool identifier
    TestERC20 token0; // First token in the pair
    TestERC20 token1; // Second token in the pair
    IPoolManager.SwapParams public swapParams; // Default swap parameters
    HookEnabledSwapRouter router; // Router for executing swaps

    // Test constants
    address user = address(0x123); // Test user address
    address constant TOKEN0 = address(0x10000); // Token0 address
    address constant TOKEN1 = address(0x20000); // Token1 address
    uint256 constant PRICE_1_1 = 1e18; // 1:1 price ratio
    uint160 constant SQRT_PRICE_1 = 79228162514264337593543950336; // Square root of 1:1 price

    /**
     * @notice Set up the test environment before each test
     * @dev Initializes contracts, deploys tokens, and sets up the pool
     */
    function setUp() public {
        // Deploy fresh manager and routers
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy and configure price oracle
        priceOracle = new PriceOracle();
        string[] memory assets = new string[](1);
        assets[0] = "TEST";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 100;
        priceOracle.updatePrices(assets, prices);

        // Initialize token contracts
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        // Configure hook flags for required functionality
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        // Deploy hook contract
        bytes memory constructorArgs = abi.encode(
            address(manager),
            address(priceOracle)
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(NewEraHook).creationCode,
            constructorArgs
        );
        hook = new NewEraHook{salt: salt}(
            IPoolManager(address(manager)),
            address(priceOracle)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Initialize pool with hook
        (key, poolId) = initPool(
            currency0,
            currency1,
            IHooks(address(hook)),
            500,
            SQRT_PRICE_1
        );

        // Set up default swap parameters
        swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 100e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_1
        });

        // Deploy and configure liquidity router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Approve tokens for hook and router
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    /**
     * @notice Test placing a limit order
     * @dev Verifies that a limit order can be created with correct parameters
     */
    function test_placeLimitOrder() public {
        vm.startPrank(user);

        // Set up order parameters
        uint256 tolerance = 100; // 1% tolerance in basis points
        bool zeroForOne = true; // Sell order (token0 for token1)
        uint256 amount = 100; // Base amount in wei

        // Prepare tokens for the order
        token0.mint(user, amount * 2);
        token1.mint(user, amount * 2);
        token0.approve(address(hook), type(uint256).max);
        // token1.approve(address(hook), type(uint256).max);
        // token0.approve(address(manager), type(uint256).max);
        // token1.approve(address(manager), type(uint256).max);

        // Calculate order amounts including fees
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            amount,
            key
        );

        // Place the limit order
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            tolerance,
            zeroForOne
        );

        // Verify order was created with correct parameters
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
            uint256 creationTimestamp
        ) = hook.limitOrders(key.toId(), user, 0);

        assertEq(orderUser, user, "Incorrect order user");
        assertEq(orderAmount, amount, "Incorrect order amount");
        assertEq(orderTolerance, tolerance, "Incorrect tolerance");
        assertEq(orderZeroForOne, zeroForOne, "Incorrect zeroForOne");
        assertTrue(isActive, "Order should be active");
        assertTrue(tokensTransferred, "Tokens should be transferred");
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

        vm.stopPrank();
    }

    /**
     * @notice Test limit order execution
     * @dev Verifies that a limit order is executed when price conditions are met
     */
    function test_limitOrderExecution() public {
        vm.startPrank(user);

        // Set up order parameters
        uint256 amount = 200;
        uint256 tolerance = 100; // 1% tolerance in basis points
        bool zeroForOne = false; // Buy order (token1 for token0)

        // Prepare tokens for the order
        token0.mint(user, amount * 2);
        token1.mint(user, amount * 2);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Calculate order amounts including fees
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            amount,
            key
        );

        // Get current oracle price

        // Prepare tokens for the buy order
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);

        // Additional approval for pool manager
        vm.stopPrank();
        token1.approve(address(manager), totalAmount);
        vm.startPrank(user);

        // Place the limit order
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            tolerance,
            zeroForOne
        );

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
            uint256 creationTimestamp
        ) = hook.limitOrders(key.toId(), user, 0);
        assertTrue(isActive, "Limit order should be created and active");
        assertFalse(orderZeroForOne, "Should be a buy order");
        assertEq(orderTotalAmount, totalAmount, "Total amount should match");
        assertEq(orderTolerance, tolerance, "Tolerance should match");
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

        vm.stopPrank();

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

        // Execute swap to trigger order execution
        bytes memory hookData = abi.encode(user);
        swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({
                takeClaims: true,
                settleUsingBurn: false
            }),
            hookData
        );

        // Verify order was executed
        (, , , , , , , bool finalIsActive, , ) = hook.limitOrders(
            key.toId(),
            user,
            0
        );
        assertFalse(
            finalIsActive,
            "Limit order should be executed and inactive"
        );
    }

    /**
     * @notice Test limit order execution in afterSwap hook
     * @dev Verifies that multiple orders are executed correctly when price conditions are met
     */
    function test_afterSwapOrderExecution() public {
        vm.startPrank(user);

        // Set up two orders with different tolerances
        uint256 amount1 = 100;
        uint256 amount2 = 200;
        uint256 tolerance1 = 200; // 2% tolerance
        uint256 tolerance2 = 100; // 1% tolerance
        bool zeroForOne = false; // Buy orders

        // Prepare tokens for both orders
        token0.mint(user, amount1 * 2);
        token1.mint(user, amount1 * 2);
        token0.mint(user, amount2 * 2);
        token1.mint(user, amount2 * 2);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Place first order
        (uint256 baseAmount1, uint256 totalAmount1) = hook
            .calculateOrderAmounts(amount1, key);
        hook.placeLimitOrder(
            key,
            baseAmount1,
            totalAmount1,
            tolerance1,
            zeroForOne
        );

        // Place second order
        (uint256 baseAmount2, uint256 totalAmount2) = hook
            .calculateOrderAmounts(amount2, key);
        hook.placeLimitOrder(
            key,
            baseAmount2,
            totalAmount2,
            tolerance2,
            zeroForOne
        );

        vm.stopPrank();

        // Add liquidity to the pool
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity in a tight range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                -10, // Lower tick
                10, // Upper tick
                10 ether, // Liquidity amount
                bytes32(0)
            ),
            ZERO_BYTES
        );

        // Create swap to trigger order execution
        uint160 targetSqrtPrice = TickMath.getSqrtPriceAtTick(5000);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1000 ether,
            sqrtPriceLimitX96: targetSqrtPrice
        });

        // Execute swap
        bytes memory hookData = abi.encode(user);
        swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({
                takeClaims: true,
                settleUsingBurn: false
            }),
            hookData
        );

        // Verify both orders were executed
        (, , , , , , , bool isActive1, , ) = hook.limitOrders(key.toId(), user, 0);
        (, , , , , , , bool isActive2, , ) = hook.limitOrders(key.toId(), user, 1);

        assertFalse(isActive1, "First order should be executed");
        assertFalse(isActive2, "Second order should be executed");
    }

    /**
     * @notice Test updating a limit order
     * @dev Verifies that an order can be updated with new parameters
     */
    function test_updateLimitOrder() public {
        vm.startPrank(user);

        // Set up initial order parameters
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100; // 1% tolerance
        bool zeroForOne = false; // Buy order

        // Calculate and prepare initial order
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);

        // Place initial order
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            zeroForOne
        );

        // Verify initial order state
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
            uint256 creationTimestamp
        ) = hook.limitOrders(key.toId(), user, 0);
        assertEq(orderAmount, initialAmount, "Initial amount should match");
        assertEq(
            orderTolerance,
            initialTolerance,
            "Initial tolerance should match"
        );
        assertTrue(isActive, "Order should be active");
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

        // Update order with new parameters
        uint256 newAmount = 200;
        uint256 newTolerance = 200; // 2% tolerance
        hook.updateLimitOrder(key, user, 0, newAmount, newTolerance);

        // Verify updated order state
        (
            orderUser,
            orderAmount,
            orderTotalAmount,
            oraclePrice,
            oraclePrice2,
            orderTolerance,
            orderZeroForOne,
            isActive,
            tokensTransferred,
            creationTimestamp
        ) = hook.limitOrders(key.toId(), user, 0);
        assertEq(orderAmount, newAmount, "Amount should be updated");
        assertEq(orderTolerance, newTolerance, "Tolerance should be updated");
        assertTrue(isActive, "Order should still be active");
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

        // Verify total amount was updated correctly
        (uint256 expectedBaseAmount, uint256 expectedTotalAmount) = hook
            .calculateOrderAmounts(newAmount, key);
        assertEq(
            orderTotalAmount,
            expectedTotalAmount,
            "Total amount should be updated correctly"
        );

        vm.stopPrank();
    }

    /**
     * @notice Test unauthorized order update
     * @dev Verifies that only the order owner can update their order
     */
    function test_RevertWhen_UpdateLimitOrderUnauthorized() public {
        // Create order as unauthorized user
        address unauthorizedUser = address(0x456);

        // Prepare tokens for unauthorized user
        vm.startPrank(unauthorizedUser);
        token1.mint(unauthorizedUser, 1000e18);
        token1.approve(address(hook), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Place order
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            false
        );

        // Verify order was created
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
            uint256 creationTimestamp
        ) = hook.limitOrders(key.toId(), unauthorizedUser, 0);
        require(isActive, "Order should be active");
        require(
            orderUser == unauthorizedUser,
            "Order should belong to unauthorized user"
        );
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

        vm.stopPrank();

        // Attempt to update order as different address
        address attacker = address(0x789);
        vm.prank(attacker);
        vm.expectRevert(NewEraHook.UnauthorizedCaller.selector);
        hook.updateLimitOrder(key, unauthorizedUser, 0, 200, 200);
    }

    /**
     * @notice Test updating order with invalid tolerance
     * @dev Verifies that orders cannot be updated with tolerance > 100%
     */
    function test_RevertWhen_UpdateLimitOrderInvalidTolerance() public {
        vm.startPrank(user);

        // Create initial order
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            false
        );

        // Attempt to update with invalid tolerance
        vm.expectRevert(LimitHelper.InvalidTolerance.selector);
        hook.updateLimitOrder(key, user, 0, 200, 10001);

        vm.stopPrank();
    }

    /**
     * @notice Test updating order with zero amount
     * @dev Verifies that orders cannot be updated with zero amount
     */
    function test_RevertWhen_UpdateLimitOrderZeroAmount() public {
        vm.startPrank(user);

        // Create initial order
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            false
        );

        // Attempt to update with zero amount
        vm.expectRevert(LimitHelper.InvalidAmount.selector);
        hook.updateLimitOrder(key, user, 0, 0, 200);

        vm.stopPrank();
    }

    /**
     * @notice Test canceling a limit order
     * @dev Verifies that an order can be canceled and tokens are returned
     */
    function test_cancelLimitOrder() public {
        vm.startPrank(user);

        // Create initial order
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);

        // Place order
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            false
        );

        // Record initial balance
        uint256 initialBalance = token1.balanceOf(user);

        // Cancel order
        hook.cancelLimitOrder(key, user, 0);

        // Verify order was cancelled
        (, , , , , , , bool isActive, , ) = hook.limitOrders(key.toId(), user, 0);
        assertFalse(isActive, "Order should be inactive after cancellation");

        // Verify tokens were returned
        uint256 finalBalance = token1.balanceOf(user);
        assertEq(
            finalBalance,
            initialBalance + totalAmount,
            "Tokens should be returned"
        );

        vm.stopPrank();
    }

    /**
     * @notice Test unauthorized order cancellation
     * @dev Verifies that only the order owner can cancel their order
     */
    function test_RevertWhen_CancelLimitOrderUnauthorized() public {
        // Create order as unauthorized user
        address unauthorizedUser = address(0x456);

        // Prepare tokens for unauthorized user
        vm.startPrank(unauthorizedUser);
        token1.mint(unauthorizedUser, 1000e18);
        token1.approve(address(hook), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Place order
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            false
        );

        // Verify order was created
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
            uint256 creationTimestamp
        ) = hook.limitOrders(key.toId(), unauthorizedUser, 0);
        require(isActive, "Order should be active");
        require(
            orderUser == unauthorizedUser,
            "Order should belong to unauthorized user"
        );
        assertEq(oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2");
        assertTrue(creationTimestamp > 0, "creationTimestamp should be set");

        vm.stopPrank();

        // Attempt to cancel order as different address
        address attacker = address(0x789);
        vm.prank(attacker);
        vm.expectRevert(NewEraHook.UnauthorizedCaller.selector);
        hook.cancelLimitOrder(key, unauthorizedUser, 0);
    }

    /**
     * @notice Test canceling an inactive order
     * @dev Verifies that inactive orders cannot be canceled
     */
    function test_RevertWhen_CancelLimitOrderNotActive() public {
        vm.startPrank(user);

        // Create initial order
        uint256 initialAmount = 100;
        uint256 initialTolerance = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            initialAmount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);

        // Place order
        hook.placeLimitOrder(
            key,
            baseAmount,
            totalAmount,
            initialTolerance,
            false
        );

        // Cancel order first time
        hook.cancelLimitOrder(key, user, 0);

        // Attempt to cancel the same order again
        vm.expectRevert(NewEraHook.NoActiveLimitOrder.selector);
        hook.cancelLimitOrder(key, user, 0);

        vm.stopPrank();
    }

    /**
     * @notice Test withdrawing funds from the contract
     * @dev Verifies that admin can withdraw funds
     */
    function test_withdrawFunds() public {
        // Create an order to have tokens in the contract
        vm.startPrank(user);
        uint256 amount = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            amount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);
        hook.placeLimitOrder(key, baseAmount, totalAmount, 100, false);
        vm.stopPrank();

        // Record initial balances
        uint256 initialHookBalance = token1.balanceOf(address(hook));
        uint256 initialAdminBalance = token1.balanceOf(address(this));

        // Withdraw funds as admin
        hook.withdrawFunds(Currency.wrap(address(token1)));

        // Verify balances after withdrawal
        uint256 finalHookBalance = token1.balanceOf(address(hook));
        uint256 finalAdminBalance = token1.balanceOf(address(this));

        assertEq(
            finalHookBalance,
            0,
            "Hook should have 0 tokens after withdrawal"
        );
        assertEq(
            finalAdminBalance,
            initialAdminBalance + initialHookBalance,
            "Admin should receive all tokens"
        );
    }

    /**
     * @notice Test unauthorized fund withdrawal
     * @dev Verifies that only admin can withdraw funds
     */
    function test_RevertWhen_WithdrawFundsUnauthorized() public {
        // Create an order to have tokens in the contract
        vm.startPrank(user);
        uint256 amount = 100;
        (uint256 baseAmount, uint256 totalAmount) = hook.calculateOrderAmounts(
            amount,
            key
        );
        token1.mint(user, totalAmount);
        token1.approve(address(hook), totalAmount);
        token1.approve(address(manager), totalAmount);
        hook.placeLimitOrder(key, baseAmount, totalAmount, 100, false);
        vm.stopPrank();

        // Attempt to withdraw as non-admin
        address attacker = address(0x789);
        vm.prank(attacker);
        vm.expectRevert(NewEraHook.OnlyAdmin.selector);
        hook.withdrawFunds(Currency.wrap(address(token1)));
    }

    /**
     * @notice Test withdrawing multiple token types
     * @dev Verifies that admin can withdraw different token types
     */
    function test_withdrawFundsMultipleTokens() public {
        // Create orders with both tokens
        vm.startPrank(user);

        // Place order with token1
        uint256 amount1 = 100;
        (uint256 baseAmount1, uint256 totalAmount1) = hook
            .calculateOrderAmounts(amount1, key);
        token1.mint(user, totalAmount1);
        token1.approve(address(hook), totalAmount1);
        token1.approve(address(manager), totalAmount1);
        hook.placeLimitOrder(key, baseAmount1, totalAmount1, 100, false);

        // Place order with token0
        uint256 amount0 = 100;
        (uint256 baseAmount0, uint256 totalAmount0) = hook
            .calculateOrderAmounts(amount0, key);
        token0.mint(user, totalAmount0);
        token0.approve(address(hook), totalAmount0);
        token0.approve(address(manager), totalAmount0);
        hook.placeLimitOrder(key, baseAmount0, totalAmount0, 100, true);

        vm.stopPrank();

        // Record initial balances
        uint256 initialHookBalance0 = token0.balanceOf(address(hook));
        uint256 initialHookBalance1 = token1.balanceOf(address(hook));
        uint256 initialAdminBalance0 = token0.balanceOf(address(this));
        uint256 initialAdminBalance1 = token1.balanceOf(address(this));

        // Withdraw token0
        hook.withdrawFunds(Currency.wrap(address(token0)));

        // Verify token0 balances
        uint256 finalHookBalance0 = token0.balanceOf(address(hook));
        uint256 finalAdminBalance0 = token0.balanceOf(address(this));
        assertEq(
            finalHookBalance0,
            0,
            "Hook should have 0 token0 after withdrawal"
        );
        assertEq(
            finalAdminBalance0,
            initialAdminBalance0 + initialHookBalance0,
            "Admin should receive all token0"
        );

        // Withdraw token1
        hook.withdrawFunds(Currency.wrap(address(token1)));

        // Verify token1 balances
        uint256 finalHookBalance1 = token1.balanceOf(address(hook));
        uint256 finalAdminBalance1 = token1.balanceOf(address(this));
        assertEq(
            finalHookBalance1,
            0,
            "Hook should have 0 token1 after withdrawal"
        );
        assertEq(
            finalAdminBalance1,
            initialAdminBalance1 + initialHookBalance1,
            "Admin should receive all token1"
        );
    }

    /**
     * @notice Test creating a TWAMM order
     * @dev Verifies that a TWAMM order can be created with correct parameters
     */
    function test_TWAMMOrder() public {
        vm.startPrank(user);
        // Set up TWAMM order parameters
        uint256 amountIn = 100 ether; // Amount to sell
        uint160 expiration = 30000;
        uint160 submitTimestamp = 10000;
        uint256 tolerance = 100; // 1% tolerance
        uint160 duration = expiration - submitTimestamp;

        // Create order key
        ITWAMM.OrderKey memory orderKey = hook.createOrderKey(
            user,
            expiration,
            true
        );

        // Prepare tokens for the order
        token0.mint(user, amountIn);
        token0.approve(address(hook), amountIn);
        token0.approve(address(manager), amountIn);

        // Verify initial order state
        ITWAMM.Order memory nullOrder = hook.getTWAMMOrder(key, orderKey);
        assertEq(nullOrder.sellRate, 0);
        assertEq(nullOrder.earningsFactorLast, 0);

        // Set timestamp and submit order
        vm.warp(submitTimestamp);
        bytes32 orderId = hook.submitTWAMMOrder(
            key,
            orderKey,
            amountIn,
            expiration,
            tolerance
        );

        // Verify order was created correctly
        ITWAMM.Order memory order = hook.getTWAMMOrder(key, orderKey);
        (
            uint256 sellRateCurrent0For1,
            uint256 earningsFactorCurrent0For1
        ) = hook.getTWAMMOrderPool(key, true);
        (
            uint256 sellRateCurrent1For0,
            uint256 earningsFactorCurrent1For0
        ) = hook.getTWAMMOrderPool(key, false);

        uint256 expectedSellRate = amountIn / duration;
        assertEq(order.sellRate, expectedSellRate);
        assertEq(order.earningsFactorLast, 0);
        assertEq(sellRateCurrent0For1, expectedSellRate);
        assertEq(sellRateCurrent1For0, 0);
        assertEq(earningsFactorCurrent0For1, 0);
        assertEq(earningsFactorCurrent1For0, 0);

        vm.stopPrank();
    }

    /**
     * @notice Test creating a TWAMM order with zero tolerance
     * @dev Verifies that a TWAMM order can be created with zero tolerance
     */
    function test_TWAMMOrderWithZeroTolerance() public {
        vm.startPrank(user);

        // Set up TWAMM order parameters
        uint256 amountIn = 100 ether;
        uint160 expiration = 30000;
        uint160 submitTimestamp = 10000;
        uint256 tolerance = 0; // Zero tolerance
        uint160 duration = expiration - submitTimestamp;

        // Create order key
        ITWAMM.OrderKey memory orderKey = hook.createOrderKey(
            user,
            expiration,
            true
        );

        // Prepare tokens
        token0.mint(user, amountIn);
        token0.approve(address(hook), amountIn);
        token0.approve(address(manager), amountIn);

        // Set timestamp and submit order
        vm.warp(submitTimestamp);
        bytes32 orderId = hook.submitTWAMMOrder(
            key,
            orderKey,
            amountIn,
            expiration,
            tolerance
        );

        // Verify order was created
        ITWAMM.Order memory order = hook.getTWAMMOrder(key, orderKey);
        assertEq(
            order.sellRate,
            amountIn / duration,
            "Order should be created with correct sell rate"
        );
        assertEq(order.tolerance, 0, "Tolerance should be zero");

        // Verify order state after execution
        order = hook.getTWAMMOrder(key, orderKey);
        (
            uint256 sellRateCurrent0For1,
            uint256 earningsFactorCurrent0For1
        ) = hook.getTWAMMOrderPool(key, true);
        (
            uint256 sellRateCurrent1For0,
            uint256 earningsFactorCurrent1For0
        ) = hook.getTWAMMOrderPool(key, false);

        assertEq(
            order.sellRate,
            amountIn / duration,
            "Order should still be active"
        );
        assertEq(
            sellRateCurrent0For1,
            amountIn / duration,
            "Order pool should have the correct sell rate"
        );
        assertEq(sellRateCurrent1For0, 0, "Other order pool should be empty");

        vm.stopPrank();
    }

    /**
     * @notice Test TWAMM order execution over time
     * @dev Verifies that TWAMM orders are executed correctly over multiple time steps
     */
    function test_TWAMMOrderExecutionOverTime() public {


        // Add liquidity first with smaller amounts
        _addLiquidity();
        // token0.mint(address(this), 100 ether);
        // token1.mint(address(this), 100 ether);
        // token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        // token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // // Add liquidity in a tight range
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams(
        //         -10, // Lower tick
        //         10, // Upper tick
        //         10 ether, // Liquidity amount
        //         bytes32(0)
        //     ),
        //     ZERO_BYTES
        // );

        vm.startPrank(user);

        // Set up TWAMM order parameters with very small amounts
        uint256 amountIn = 0.001 ether; // Further reduced amount
        uint160 submitTimestamp = 10000;
        uint160 expiration = submitTimestamp + 100;
        uint256 tolerance = 100;
        uint160 duration = expiration - submitTimestamp;

        // Create order key
        ITWAMM.OrderKey memory orderKey = hook.createOrderKey(
            user,
            expiration,
            true
        );

        // Prepare tokens for the order - mint more tokens to ensure enough balance
        token0.mint(user, 1 ether);
        token1.mint(user, 1 ether);
        token0.approve(address(hook), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Log initial state
        console.log("Initial Token0 Balance:", token0.balanceOf(user));
        console.log("Initial Token1 Balance:", token1.balanceOf(user));

        // Get initial pool state
        (uint256 sellRateCurrent0For1, uint256 earningsFactorCurrent0For1) = hook.getTWAMMOrderPool(key, true);
        console.log("Initial Pool State - Sell Rate 0->1:", sellRateCurrent0For1);
        console.log("Initial Pool State - Earnings Factor:", earningsFactorCurrent0For1);

        // Submit order
        vm.warp(submitTimestamp);
        bytes32 orderId = hook.submitTWAMMOrder(
            key,
            orderKey,
            amountIn,
            expiration,
            tolerance
        );

        // Verify order was created
        ITWAMM.Order memory order = hook.getTWAMMOrder(key, orderKey);
        uint256 expectedSellRate = amountIn / duration;
        console.log("Expected Sell Rate:", expectedSellRate);
        console.log("Actual Sell Rate:", order.sellRate);
        assertEq(
            order.sellRate,
            expectedSellRate,
            "Sell rate should match expected rate"
        );
        assertEq(
            order.earningsFactorLast,
            0,
            "Initial earnings factor should be 0"
        );
        vm.stopPrank();

        // Execute order in smaller chunks
        for (uint160 t = submitTimestamp + 20; t <= expiration; t += 20) {
            vm.warp(t);

            // Log state before execution
            console.log("\nTime:", t);
            uint256 token0BalanceBefore = token0.balanceOf(user);
            uint256 token1BalanceBefore = token1.balanceOf(user);
            console.log("Token0 Balance Before:", token0BalanceBefore);
            console.log("Token1 Balance Before:", token1BalanceBefore);

            // Get pool state before execution
            (sellRateCurrent0For1, earningsFactorCurrent0For1) = hook.getTWAMMOrderPool(key, true);
            console.log("Pool State Before - Sell Rate:", sellRateCurrent0For1);
            console.log("Pool State Before - Earnings Factor:", earningsFactorCurrent0For1);

            // Execute a swap to move the price to a level that allows TWAMM execution
            if (t == submitTimestamp + 20) {
                // Create swap parameters to move price to a level that allows execution
                IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                    zeroForOne: false, // Swap token1 for token0 to increase price
                    amountSpecified: 0.001 ether, // Further reduced amount
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(2) // Minimal price movement
                });

                // Execute the swap
                bytes memory hookData = abi.encode(user);
                swapRouter.swap(
                    key,
                    params,
                    PoolSwapTest.TestSettings({
                        takeClaims: true,
                        settleUsingBurn: false
                    }),
                    hookData
                );
                console.log("test");
            }


            // Execute TWAMM orders
            // vm.startPrank(user);
            hook.executeTWAMMOrders(key);
            // vm.stopPrank();

            // Get pool state after execution
            (sellRateCurrent0For1, earningsFactorCurrent0For1) = hook.getTWAMMOrderPool(key, true);
            console.log("Pool State After - Sell Rate:", sellRateCurrent0For1);
            console.log("Pool State After - Earnings Factor:", earningsFactorCurrent0For1);

            // Log state after execution
            uint256 token0BalanceAfter = token0.balanceOf(user);
            uint256 token1BalanceAfter = token1.balanceOf(user);
            console.log("Token0 Balance After:", token0BalanceAfter);
            console.log("Token1 Balance After:", token1BalanceAfter);

            // Get current order state
            order = hook.getTWAMMOrder(key, orderKey);
            console.log("Current Sell Rate:", order.sellRate);
            
            // Verify that some tokens were swapped in this chunk
            assertTrue(
                token0BalanceAfter < token0BalanceBefore,
                "Token0 balance should decrease after execution"
            );
            assertTrue(
                token1BalanceAfter > token1BalanceBefore,
                "Token1 balance should increase after execution"
            );
        }

        // Final verification
        order = hook.getTWAMMOrder(key, orderKey);
        console.log("\nFinal State:");
        console.log("Final Token0 Balance:", token0.balanceOf(user));
        console.log("Final Token1 Balance:", token1.balanceOf(user));
        console.log("Final Sell Rate:", order.sellRate);

        // Verify that the order was fully executed
        assertEq(order.sellRate, 0, "Order should be fully executed");
        assertTrue(
            token0.balanceOf(user) < amountIn,
            "Most of token0 should be swapped"
        );
        assertTrue(
            token1.balanceOf(user) > 0,
            "Should receive some token1"
        );

        
    }

    /**
     * @notice Helper function to add liquidity to the pool
     * @dev Adds liquidity in a tight range around the current price
     */
    function _addLiquidity() internal {
        // Add smaller amount of liquidity
        uint256 amount0 = 10 ether;
        uint256 amount1 = 10 ether;
        
        token0.mint(user, amount0);
        token1.mint(user, amount1);
        
        token0.approve(address(modifyLiquidityRouter), amount0);
        token1.approve(address(modifyLiquidityRouter), amount1);
        
        // Add liquidity in a very tight range around current price
        int24 tickLower = -10;
        int24 tickUpper = 10;
        
        // Use the modifyLiquidityRouter to add liquidity with smaller amount
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 100000000, // Significantly reduced liquidity amount
                salt: bytes32(0)
            }),
            ""
        );
    }

    /**
     * @notice Test getting user limit orders
     * @dev Verifies that getUserLimitOrders returns all orders (active and inactive) for the caller
     */
    function test_getUserLimitOrders_returnsAllOrders() public {
        vm.startPrank(user);

        // Set up order parameters for pool 1
        uint256 tolerance1 = 100; // 1% tolerance in basis points
        bool zeroForOne1 = true; // Sell order (token0 for token1)
        uint256 amount1 = 100; // Base amount in wei

        // Prepare tokens for the order
        token0.mint(user, amount1 * 2);
        token1.mint(user, amount1 * 2);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Calculate order amounts including fees
        (uint256 baseAmount1, uint256 totalAmount1) = hook.calculateOrderAmounts(
            amount1,
            key
        );

        // Place the limit order in pool 1
        hook.placeLimitOrder(
            key,
            baseAmount1,
            totalAmount1,
            tolerance1,
            zeroForOne1
        );

        (uint24 newFee, uint160 newSqrtPrice) = (key.fee + 1, SQRT_PRICE_1); // or any valid sqrt price
        (PoolKey memory key2, ) = initPool(currency0, currency1, IHooks(address(hook)), newFee, newSqrtPrice);
        // Place a limit order in pool 2
        uint256 tolerance2 = 200;
        bool zeroForOne2 = false;
        uint256 amount2 = 200;
        (uint256 baseAmount2, uint256 totalAmount2) = hook.calculateOrderAmounts(
            amount2,
            key2
        );
        token1.mint(user, amount2 * 2);
        token1.approve(address(hook), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        hook.placeLimitOrder(
            key2,
            baseAmount2,
            totalAmount2,
            tolerance2,
            zeroForOne2
        );

        // Call the new getUserLimitOrders (no argument)
        NewEraHook.LimitOrder[] memory orders = hook.getUserLimitOrders();
        assertEq(orders.length, 2, "Should return all orders across all pools");

        // Check first order (pool 1)
        assertEq(orders[0].user, user, "Incorrect order user (1)");
        assertEq(orders[0].amount, amount1, "Incorrect order amount (1)");
        assertEq(orders[0].tolerance, tolerance1, "Incorrect tolerance (1)");
        assertEq(orders[0].zeroForOne, zeroForOne1, "Incorrect zeroForOne (1)");
        assertTrue(orders[0].isActive, "Order should be active (1)");
        assertTrue(orders[0].tokensTransferred, "Tokens should be transferred (1)");
        assertEq(orders[0].oraclePrice2, LimitHelper.getOraclePrice2(key, priceOracle), "Incorrect oraclePrice2 (1)");
        assertTrue(orders[0].creationTimestamp > 0, "creationTimestamp should be set (1)");

        // Check second order (pool 2)
        assertEq(orders[1].user, user, "Incorrect order user (2)");
        assertEq(orders[1].amount, amount2, "Incorrect order amount (2)");
        assertEq(orders[1].tolerance, tolerance2, "Incorrect tolerance (2)");
        assertEq(orders[1].zeroForOne, zeroForOne2, "Incorrect zeroForOne (2)");
        assertTrue(orders[1].isActive, "Order should be active (2)");
        assertTrue(orders[1].tokensTransferred, "Tokens should be transferred (2)");
        assertEq(orders[1].oraclePrice2, LimitHelper.getOraclePrice2(key2, priceOracle), "Incorrect oraclePrice2 (2)");
        assertTrue(orders[1].creationTimestamp > 0, "creationTimestamp should be set (2)");

        vm.stopPrank();
    }

    /**
     * @notice Test getting user TWAMM orders
     * @dev Verifies that getUserTWAMMOrders returns all TWAMM orders (active and inactive) for the caller
     */
    function test_getUserTWAMMOrders_returnsAllOrders() public {
        vm.startPrank(user);

        // Set up TWAMM order parameters for pool 1
        uint256 amountIn1 = 1 ether;
        uint160 expiration1 = 30000;
        uint160 submitTimestamp1 = 10000;
        uint256 tolerance1 = 100;
        uint160 duration1 = expiration1 - submitTimestamp1;
        ITWAMM.OrderKey memory orderKey1 = hook.createOrderKey(user, expiration1, true);
        token0.mint(user, amountIn1);
        token0.approve(address(hook), amountIn1);
        token0.approve(address(manager), amountIn1);
        vm.warp(submitTimestamp1);
        bytes32 orderId1 = hook.submitTWAMMOrder(key, orderKey1, amountIn1, expiration1, tolerance1);

        // Set up TWAMM order parameters for pool 2 (different fee)
        (uint24 newFee, uint160 newSqrtPrice) = (key.fee + 1, SQRT_PRICE_1);
        (PoolKey memory key2, ) = initPool(currency0, currency1, IHooks(address(hook)), newFee, newSqrtPrice);
        uint256 amountIn2 = 2 ether;
        uint160 expiration2 = 40000;
        uint160 submitTimestamp2 = 20000;
        uint256 tolerance2 = 200;
        uint160 duration2 = expiration2 - submitTimestamp2;
        ITWAMM.OrderKey memory orderKey2 = hook.createOrderKey(user, expiration2, false);
        token1.mint(user, amountIn2);
        token1.approve(address(hook), amountIn2);
        token1.approve(address(manager), amountIn2);
        vm.warp(submitTimestamp2);
        bytes32 orderId2 = hook.submitTWAMMOrder(key2, orderKey2, amountIn2, expiration2, tolerance2);

        // Call the new getUserTWAMMOrders (no argument)
        (ITWAMM.Order[] memory orders, ITWAMM.OrderKey[] memory orderKeys) = hook.getUserTWAMMOrders();
        assertEq(orders.length, 2, "Should return all TWAMM orders across all pools");
        assertEq(orderKeys.length, 2, "Should return all TWAMM order keys");

        // Check first order (pool 1)
        assertEq(orderKeys[0].owner, user, "Incorrect order owner (1)");
        assertEq(orderKeys[0].expiration, expiration1, "Incorrect expiration (1)");
        assertEq(orderKeys[0].zeroForOne, true, "Incorrect zeroForOne (1)");
        assertEq(orders[0].sellRate, amountIn1 / duration1, "Incorrect sellRate (1)");
        assertEq(orders[0].tolerance, tolerance1, "Incorrect tolerance (1)");

        // Check second order (pool 2)
        assertEq(orderKeys[1].owner, user, "Incorrect order owner (2)");
        assertEq(orderKeys[1].expiration, expiration2, "Incorrect expiration (2)");
        assertEq(orderKeys[1].zeroForOne, false, "Incorrect zeroForOne (2)");
        assertEq(orders[1].sellRate, amountIn2 / duration2, "Incorrect sellRate (2)");
        assertEq(orders[1].tolerance, tolerance2, "Incorrect tolerance (2)");

        vm.stopPrank();
    }
}

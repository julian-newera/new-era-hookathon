// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAttestationCenter} from "../src/interfaces/IAttestationCenter.sol";
import {DynamicPricesAvsHook, Epoch, EpochLibrary} from "../src/PriceAvsHook.sol";
import {MockAttestationCenter} from "../src/mocks/MockAttestationCenter.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {console} from "forge-std/console.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {HookEnabledSwapRouter} from "../utils/HookEnabledSwapRouter.sol";
import {ITWAMM} from "../src/interfaces/ITWAMM.sol";

contract DynamicPricesAvsHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    
    DynamicPricesAvsHook avsHook;
    MockAttestationCenter attestationCenter;
    // PoolKey key;
    IPoolManager.SwapParams public swapParams;
    PoolId id;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    address constant TOKEN0 = address(0x10000);
    address constant TOKEN1 = address(0x20000);
    uint256 constant PRICE_1_1 = 1e18; // 1:1 price
    uint160 constant SQRT_PRICE_1 = 79228162514264337593543950336;

    function setUp() external {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        attestationCenter = new MockAttestationCenter();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        // Set up hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG 
        );
        
        // Deploy hook with correct constructor args
        bytes memory constructorArgs = abi.encode(address(attestationCenter), IPoolManager(address(manager)), 1000);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicPricesAvsHook).creationCode,
            constructorArgs
        );

        // Deploy hook with same salt to ensure address matches
        avsHook = new DynamicPricesAvsHook{salt: salt}(address(attestationCenter), IPoolManager(address(manager)), 1000);
        require(address(avsHook) == hookAddress, "Hook address mismatch");

        attestationCenter.setAvsLogic(address(avsHook));

        console.log("Attestation center set");
        console.log(address(avsHook));

        // Initialize pool with tokens
        (key, id) = initPool(
            currency0,
            currency1,
            IHooks(address(avsHook)),
            500, // 0.3% fee
            SQRT_PRICE_1
        );

        console.log("Pool created");

        // Setup default swap params
        swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 100e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_1
        });

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        token0.approve(address(avsHook), type(uint256).max);
        // token1.approve(address(avsHook), type(uint256).max);
        // token0.approve(address(router), type(uint256).max);
        // token1.approve(address(router), type(uint256).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INITIALIZATION TESTS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_initialState() external view {
        assertEq(avsHook.ATTESTATION_CENTER(), address(attestationCenter), "Invalid attestation center");
        assertEq(avsHook.tokenPrices(keccak256(abi.encodePacked(TOKEN0, TOKEN1))), 0, "Initial price should be 0");
    }

    function test_getHookPermissions() external view {
        Hooks.Permissions memory permissions = avsHook.getHookPermissions();
        assertTrue(permissions.beforeSwap, "beforeSwap should be enabled");
        assertTrue(permissions.afterSwap, "afterSwap should be enabled");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     TASK SUBMISSION TESTS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_afterTaskSubmission_RevertIfNotAttestationCenter() public {
        vm.expectRevert(DynamicPricesAvsHook.OnlyAttestationCenter.selector);
        avsHook.afterTaskSubmission(
            createTask(TOKEN0, TOKEN1, PRICE_1_1),
            true,
            "",
            [uint256(0), uint256(0)],
            new uint256[](0)
        );
    }

    function test_afterTaskSubmission_UpdatePriceWhenApproved() public {
        uint256 newPrice = 1.5e18; // 1.5:1 price
        bytes32 priceKey = keccak256(abi.encodePacked(TOKEN0, TOKEN1));
        
        vm.expectEmit(true, true, true, true);
        emit DynamicPricesAvsHook.PriceUpdated(TOKEN0, TOKEN1, newPrice);
        
        attestationCenter.submitPriceUpdate(TOKEN0, TOKEN1, newPrice);
        assertEq(avsHook.tokenPrices(priceKey), newPrice, "Price not updated");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         SWAP TESTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_beforeSwap_AllowWithinTolerance() public {
        // Set trusted price to 1:1
        attestationCenter.submitPriceUpdate(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            1e18
        );

        // Get current pool price
        (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        // Calculate a price limit that allows for movement within 1% tolerance
        uint160 priceLimit = swapParams.zeroForOne ? 
            (currentSqrtPriceX96 * 99) / 100 : // For token0->token1, price decreases
            (currentSqrtPriceX96 * 101) / 100; // For token1->token0, price increases

        // Perform a small swap that keeps price within tolerance
        IPoolManager.SwapParams memory swap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: priceLimit
        });

        // This should succeed as the pool price will still be within 1% of expected
        swapRouter.swap(key, swap, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");

        // Verify the pool price is still within bounds
        (currentSqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint160 expectedSqrtPriceX96 = SQRT_PRICE_1_1;
        assertTrue(
            currentSqrtPriceX96 >= (expectedSqrtPriceX96 * 99) / 100 &&
            currentSqrtPriceX96 <= (expectedSqrtPriceX96 * 101) / 100,
            "Pool price outside tolerance"
        );
    }

    function test_beforeSwap_RevertExcessivePrice() public {
        // Set trusted price to 1:1
        attestationCenter.submitPriceUpdate(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            2e18
        );

        // Get current pool price
        (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        // Calculate a price limit that allows for movement within 1% tolerance
        // Using division first to avoid overflow
        uint160 priceLimit = swapParams.zeroForOne ? 
            currentSqrtPriceX96 - (currentSqrtPriceX96 / 100) : // For token0->token1, price decreases
            currentSqrtPriceX96 + (currentSqrtPriceX96 / 100); // For token1->token0, price increases

        // Perform a large swap that would move price beyond tolerance
        IPoolManager.SwapParams memory swap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 10e18, // Much smaller swap amount
            sqrtPriceLimitX96: priceLimit
        });

        // This should revert as the pool price would move beyond 1% threshold
        vm.expectRevert(DynamicPricesAvsHook.ExecutionPriceTooHigh.selector);
        swapRouter.swap(key, swap, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    function test_beforeSwap_AllowIfNoPriceSet() public {
        // No price set in the contract

        // Get current pool price
        (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        // Calculate a price limit that allows for movement within 1% tolerance
        uint160 priceLimit = swapParams.zeroForOne ? 
            (currentSqrtPriceX96 * 99) / 100 : // For token0->token1, price decreases
            (currentSqrtPriceX96 * 101) / 100; // For token1->token0, price increases

        // Even a large swap should be allowed
        IPoolManager.SwapParams memory swap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1000e18,
            sqrtPriceLimitX96: priceLimit
        });

        // This should succeed as no price is set
        swapRouter.swap(key, swap, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    function test_beforeSwap_BothDirections() public {
        // Set trusted price to 1:1
        attestationCenter.submitPriceUpdate(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            1e18
        );

        // Get current pool price
        (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(key.toId());

        // Calculate price limits for both directions
        uint160 priceLimit0For1 = (currentSqrtPriceX96 * 99) / 100; // For token0->token1, price decreases
        uint160 priceLimit1For0 = (currentSqrtPriceX96 * 101) / 100; // For token1->token0, price increases

        // Test token0 -> token1
        IPoolManager.SwapParams memory swap0For1 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: priceLimit0For1
        });

        swapRouter.swap(key, swap0For1, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");

        // Test token1 -> token0
        IPoolManager.SwapParams memory swap1For0 = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: priceLimit1For0
        });

        swapRouter.swap(key, swap1For0, PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HELPER FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function createTask(address base, address quote, uint256 price) internal pure returns (IAttestationCenter.TaskInfo memory) {
        return IAttestationCenter.TaskInfo({
            proofOfTask: "proof",
            data: abi.encode(base, quote, price),
            taskPerformer: address(0),
            taskDefinitionId: 1
        });
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HELPER FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testZeroLiquidityRevert() public {
        vm.expectRevert(DynamicPricesAvsHook.ZeroLiquidity.selector);
        avsHook.place(key, 0, true, 0);
    }

    function testZeroForOneRightBoundaryOfCurrentRange() public {
        // Check tick spacing first
        console.log("Tick spacing:", key.tickSpacing);
        
        // For zeroForOne, the tick should be below the current tick (0)
        // Use negative tick that's multiple of tickSpacing
        int24 tickLower = -60;
        console.log("Using tickLower:", tickLower);
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        
        // Get current pool state before
        (uint160 sqrtPriceX96Before, int24 currentTick,,) = manager.getSlot0(key.toId());
        console.log("Current sqrtPrice before:", sqrtPriceX96Before);
        console.log("Current tick:", currentTick);
        
        // Call place with try/catch to see if it reverts
        try avsHook.place(key, tickLower, zeroForOne, liquidity) {
            console.log("Place succeeded");
            
            // Check if epoch was set correctly
            Epoch epoch = avsHook.getEpoch(key, tickLower, zeroForOne);
            console.log("Epoch:", uint256(Epoch.unwrap(epoch)));
            assertTrue(EpochLibrary.equals(epoch, Epoch.wrap(1)), "Epoch should be 1");
            
            // Get position info using Position library and StateLibrary
            bytes32 positionKey = Position.calculatePositionKey(address(avsHook), tickLower, tickLower + key.tickSpacing, bytes32(0));
            (uint128 posLiquidity,,) = manager.getPositionInfo(id, positionKey);
            console.log("Position liquidity:", posLiquidity);
            
            // Verify liquidity
            assertEq(posLiquidity, liquidity, "Position liquidity should match");
        } catch Error(string memory reason) {
            console.log("Place reverted with reason:", reason);
            fail();
        } catch (bytes memory lowLevelData) {
            console.log("Place reverted with no reason");
            bytes4 selector = bytes4(lowLevelData);
            if (selector == DynamicPricesAvsHook.InRange.selector) {
                console.log("Error: InRange");
            } else if (selector == DynamicPricesAvsHook.CrossedRange.selector) {
                console.log("Error: CrossedRange");
            } else {
                console.log("Unknown selector:", uint32(selector));
            }
            fail();
        }
    }

    function testAddLiquidityDirectly() public {
        // Get current tick and pool info
        (uint160 sqrtPriceX96Before, int24 currentTick,,) = manager.getSlot0(key.toId());
        console.log("Current sqrtPrice:", sqrtPriceX96Before);
        console.log("Current tick:", currentTick);
        console.log("Tick spacing:", key.tickSpacing);
        
        // For tick spacing of 60, use valid values that won't cause overflow
        // Ensure tickLower < tickUpper and both are multiples of tickSpacing
        int24 tickLower = -60;
        int24 tickUpper = 0;
        console.log("tickLower:", tickLower);
        console.log("tickUpper:", tickUpper);
        
        // Add some safety checks
        require(tickLower < tickUpper, "tickLower must be less than tickUpper");
        require(tickLower % key.tickSpacing == 0, "tickLower must be a multiple of tickSpacing");
        require(tickUpper % key.tickSpacing == 0, "tickUpper must be a multiple of tickSpacing");
        
        uint128 liquidity = 1000000;
        
        // Add liquidity directly via the liquidity router
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        
        // Check the position was created properly
        bytes32 positionKey = Position.calculatePositionKey(
            address(modifyLiquidityRouter), 
            tickLower, 
            tickUpper, 
            bytes32(0)
        );
        
        (uint128 posLiquidity,,) = manager.getPositionInfo(id, positionKey);
        console.log("Position liquidity:", posLiquidity);
        assertEq(posLiquidity, liquidity, "Position liquidity should match");
    }

    function testPlaceSimplified() public {
        // First, let's understand what ticks are valid for place
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(key.toId());
        // console.log("Current tick:", key.toId());
        console.log("Current tick:", currentTick);
        console.log("Tick spacing:", key.tickSpacing);
        
        // For zeroForOne with place() function, tick must be below the current tick
        // and we need exactly one tick (not a range) for the place function
        
        // Calculate valid tick for place: below current tick and multiple of tickSpacing
        int24 tickLower = 60;         // For zero or negative ticks
        
        console.log("Using tickLower:", tickLower);
        
        // Ensure tick is valid
        // require(tickLower % key.tickSpacing == 0, "tickLower not a multiple of tickSpacing");
        // require(tickLower < currentTick, "tickLower must be below current tick");
        
        bool zeroForOne = true;
        uint128 liquidity = 100;
        
        // Get token0 balance before
        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        console.log("Token0 balance before:", token0BalanceBefore);
        
        // Call place with try/catch to see if it reverts
        try avsHook.place(key, tickLower, zeroForOne, liquidity) {
            console.log("Place succeeded");
            
            // Get token0 balance after
            uint256 token0BalanceAfter = token0.balanceOf(address(this));
            console.log("Token0 balance after:", token0BalanceAfter);
            console.log("Token0 spent:", token0BalanceBefore - token0BalanceAfter);
            
            // Check epoch
            Epoch epoch = avsHook.getEpoch(key, tickLower, zeroForOne);
            console.log("Epoch:", uint256(Epoch.unwrap(epoch)));
            assertTrue(EpochLibrary.equals(epoch, Epoch.wrap(1)), "Epoch should be 1");
            
            // Check position liquidity via epoch instead of directly accessing position
            uint256 epochLiquidity = avsHook.getEpochLiquidity(epoch, address(this));
            console.log("Epoch liquidity:", epochLiquidity);
            assertEq(epochLiquidity, liquidity, "Epoch liquidity should match");
        } catch Error(string memory reason) {
            console.log("Place reverted with reason:", reason);
            fail();
        } catch (bytes memory lowLevelData) {
            console.log("Place reverted with no reason");
            bytes4 selector = bytes4(lowLevelData);
            if (selector == DynamicPricesAvsHook.InRange.selector) {
                console.log("Error: InRange");
            } else if (selector == DynamicPricesAvsHook.CrossedRange.selector) {
                console.log("Error: CrossedRange");
            } else {
                console.log("Unknown selector:", uint32(selector));
            }
            fail();
        }
    }

    function testSimpleLiquidityAddition() public {
        console.log("Starting simple liquidity test");
        
        // Get current info
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(key.toId());
        console.log("Current tick:", currentTick);
        console.log("Tick spacing:", key.tickSpacing);
        
        // For current tick 0 and tick spacing 60, use a range like [-60, 60]
        // This ensures the current tick is strictly between the boundaries
        int24 tickLower = -60;  // One tick spacing below current tick
        int24 tickUpper = 60;   // One tick spacing above current tick
        
        // Ensure the current tick is inside the range (not at the boundary)
        if (currentTick == tickLower) {
            tickLower = tickLower - key.tickSpacing;
        } else if (currentTick == tickUpper) {
            tickUpper = tickUpper + key.tickSpacing;
        }
        
        console.log("Final ticks:");
        console.log("tickLower:", tickLower);
        console.log("currentTick:", currentTick);
        console.log("tickUpper:", tickUpper);
        console.log("Validation: tickLower < currentTick < tickUpper:", 
            (tickLower < currentTick) && (currentTick < tickUpper));
        
        // Double-check ticks are valid
        require(tickLower % key.tickSpacing == 0, "tickLower not multiple of spacing");
        require(tickUpper % key.tickSpacing == 0, "tickUpper not multiple of spacing");
        require(tickLower < tickUpper, "tickLower must be less than tickUpper");
        require(tickLower < currentTick, "currentTick must be greater than tickLower");
        require(currentTick < tickUpper, "currentTick must be less than tickUpper");
        
        uint128 liquidity = 1000000;
        
        // Try to add liquidity 
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        ) {
            console.log("Liquidity added successfully");
            
            // Check the position was created properly
            bytes32 positionKey = Position.calculatePositionKey(
                address(modifyLiquidityRouter), 
                tickLower, 
                tickUpper, 
                bytes32(0)
            );
            
            (uint128 posLiquidity,,) = manager.getPositionInfo(id, positionKey);
            console.log("Position liquidity:", posLiquidity);
            assertEq(posLiquidity, liquidity, "Position liquidity should match");
            
        } catch Error(string memory reason) {
            console.log("Failed to add liquidity:", reason);
            fail();
        } catch (bytes memory lowLevelData) {
            console.log("Failed to add liquidity with no reason");
            if (lowLevelData.length >= 4) {
                bytes4 selector = bytes4(lowLevelData);
                console.log("Error selector:", uint32(selector));
            }
            fail();
        }
    }

    struct OrderKey {
        address owner;
        uint256 expiration;
        bool zeroForOne;
    }

    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    function testTWAMM_submitOrder_storesOrderWithCorrectPoolAndOrderPoolInfo() public {
        uint160 expiration = 30000;
        uint160 submitTimestamp = 10000;
        uint160 duration = expiration - submitTimestamp;

        ITWAMM.OrderKey memory orderKey = ITWAMM.OrderKey(address(this), expiration, true);

        ITWAMM.Order memory nullOrder = avsHook.getOrder(key, orderKey);
        assertEq(nullOrder.sellRate, 0);
        assertEq(nullOrder.earningsFactorLast, 0);

        vm.warp(10000);
        // token0.approve(address(twamm), 100 ether);
        // snapStart("TWAMMSubmitOrder");
        avsHook.submitOrder(key, orderKey, 1 ether);
        // snapEnd();
        console.log("Liquidity added successfully");

        ITWAMM.Order memory submittedOrder = avsHook.getOrder(key, orderKey);
        console.log("currentTick:", submittedOrder.sellRate);
        (uint256 sellRateCurrent0For1, uint256 earningsFactorCurrent0For1) = avsHook.getOrderPool(key, true);
        (uint256 sellRateCurrent1For0, uint256 earningsFactorCurrent1For0) = avsHook.getOrderPool(key, false);

        assertEq(submittedOrder.sellRate, 1 ether / duration);
        assertEq(submittedOrder.earningsFactorLast, 0);
        assertEq(sellRateCurrent0For1, 1 ether / duration);
        assertEq(sellRateCurrent1For0, 0);
        assertEq(earningsFactorCurrent0For1, 0);
        assertEq(earningsFactorCurrent1For0, 0);
    }
}
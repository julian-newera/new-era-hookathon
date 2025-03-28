// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAttestationCenter} from "../src/interfaces/IAttestationCenter.sol";
import {NewEraHook, Epoch, EpochLibrary} from "../src/NewEraHook.sol";
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

contract NewEraHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    
    NewEraHook avsHook;
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
            type(NewEraHook).creationCode,
            constructorArgs
        );

        // Deploy hook with same salt to ensure address matches
        avsHook = new NewEraHook{salt: salt}(address(attestationCenter), IPoolManager(address(manager)), 1000);
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
        vm.expectRevert(NewEraHook.OnlyAttestationCenter.selector);
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
        emit NewEraHook.PriceUpdated(TOKEN0, TOKEN1, newPrice);
        
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
        vm.expectRevert(NewEraHook.ZeroLiquidity.selector);
        avsHook.place(key, 0, true, 0);
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
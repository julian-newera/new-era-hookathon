// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface ITWAMM {
    /// @notice Thrown when account other than owner attempts to interact with an order
    /// @param owner The owner of the order
    /// @param currentAccount The invalid account attempting to interact with the order
    error MustBeOwner(address owner, address currentAccount);

    /// @notice Thrown when trying to cancel an already completed order
    /// @param orderKey The orderKey
    error CannotModifyCompletedOrder(OrderKey orderKey);

    /// @notice Thrown when trying to submit an order with an expiration that isn't on the interval.
    /// @param expiration The expiration timestamp of the order
    error ExpirationNotOnInterval(uint256 expiration);

    /// @notice Thrown when trying to submit an order with an expiration time in the past.
    /// @param expiration The expiration timestamp of the order
    error ExpirationLessThanBlocktime(uint256 expiration);

    /// @notice Thrown when trying to submit an order without initializing TWAMM state first
    error NotInitialized();

    /// @notice Thrown when trying to submit an order that's already ongoing.
    /// @param orderKey The already existing orderKey
    error OrderAlreadyExists(OrderKey orderKey);

    /// @notice Thrown when trying to interact with an order that does not exist.
    /// @param orderKey The already existing orderKey
    error OrderDoesNotExist(OrderKey orderKey);

    /// @notice Thrown when trying to subtract more value from a long term order than exists
    /// @param orderKey The orderKey
    /// @param unsoldAmount The amount still unsold
    /// @param amountDelta The amount delta for the order
    error InvalidAmountDelta(OrderKey orderKey, uint256 unsoldAmount, int256 amountDelta);

    /// @notice Thrown when submitting an order with a sellRate of 0
    error SellRateCannotBeZero();

    /// @notice Information associated with a long term order
    /// @member sellRate Amount of tokens sold per interval
    /// @member earningsFactorLast The accrued earnings factor from which to start claiming owed earnings for this order
    /// @member tolerance The tolerance for price deviation
    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
        uint256 tolerance;
    }

    /// @notice Information that identifies an order
    /// @member owner Owner of the order
    /// @member expiration Timestamp when the order expires
    /// @member zeroForOne Bool whether the order is zeroForOne
    struct OrderKey {
        address owner;
        uint256 expiration;
        bool zeroForOne;
    }

    /// @notice Emitted when a new long term order is submitted
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner of the new order
    /// @param expiration The expiration timestamp of the order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The sell rate of tokens per second being sold in the order
    /// @param earningsFactorLast The current earningsFactor of the order pool
    /// @param tolerance The tolerance for price deviation in basis points (e.g., 100 = 1%)
    event SubmitOrder(
        PoolId poolId,
        address indexed owner,
        uint256 indexed expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast,
        uint256 tolerance
    );

    /// @notice Emitted when a long term order is updated
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner of the existing order
    /// @param expiration The expiration timestamp of the order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The updated sellRate of tokens per second being sold in the order
    /// @param earningsFactorLast The current earningsFactor of the order pool
    /// @param tolerance The updated tolerance for price deviation in basis points
    event UpdateOrder(
        PoolId poolId,
        address indexed owner,
        uint256 indexed expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast,
        uint256 tolerance
    );


    /// @notice Submits a new long term order into the TWAMM. Also executes TWAMM orders if not up to date.
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for the new order
    /// @param amountIn The amount of sell token to add to the order. Some precision on amountIn may be lost up to the
    /// magnitude of (orderKey.expiration - block.timestamp)
    /// @param expirationInterval The interval for the order's expiration
    /// @param tolerance The tolerance for price deviation in basis points (e.g., 100 = 1%)
    /// @return orderId The bytes32 ID of the order
    function submitTWAMMOrder(
        PoolKey calldata key,
        OrderKey memory orderKey,
        uint256 amountIn,
        uint256 expirationInterval,
        uint256 tolerance
    ) external returns (bytes32 orderId);

    /// @notice Update an existing long term order with current earnings, optionally modify the amount selling.
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for which to identify the order
    /// @param amountDelta The delta for the order sell amount. Negative to remove from order, positive to add, or
    ///    -1 to remove full amount from order.
    /// @param newExpiration The new expiration timestamp for the order. Set to 0 to keep current expiration.
    /// @param expirationInterval The interval for the order's expiration
    /// @param newTolerance The new tolerance for price deviation in basis points. Set to 0 to keep current tolerance.
    function updateTWAMMOrder(
        PoolKey memory key, 
        OrderKey memory orderKey, 
        int256 amountDelta,
        uint256 newExpiration,
        uint256 expirationInterval,
        uint256 newTolerance
    ) external returns (uint256 tokens0Owed, uint256 tokens1Owed);

    /// @notice Claim tokens owed from TWAMM contract
    /// @param token The token to claim
    /// @param to The receipient of the claim
    /// @param amountRequested The amount of tokens requested to claim. Set to 0 to claim all.
    /// @return amountTransferred The total token amount to be collected
    function claimTWAMMTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred);

    /// @notice Executes TWAMM orders on the pool, swapping on the pool itself to make up the difference between the
    /// two TWAMM pools swapping against each other
    /// @param key The pool key associated with the TWAMM
    function executeTWAMMOrders(PoolKey memory key) external;

    function tokensOwed(Currency token, address owner) external returns (uint256);

    function getTWAMMOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory);
}
# NewEra Finance

#### Smart Hook for Real World Assets with automatic DCA execution and oracle-based limit orders.

## Links

- **GitHub:** https://github.com/julian-newera/new-era-hookathon
- **Presentation:** https://docsend.com/view/b2hau5g8t7u4r7d7

## Introduction

NewEra Finance allows users to invest automatically in a portfolio of Real World Assets (RWAs), featuring Dollar Cost Averaging (DCA) and oracle-based limit orders — making investing in RWAs a regular habit, rather than a hassle.

Users can schedule DCA trades on their chosen RWA Tokens. To optimize pricing, even in low liquidity markets, the Hook sets limit orders via price oracles aligned with the underlying RWA issuance/redemption price. This concept is similar to slippage. Users can set their tolerance level for the premium they are willing to pay above the asset's value. The higher the tolerance, the quicker the execution, as the position becomes more attractive for arbitrage. The Auto-Limit Order logic works as follows:

- If pool price ≤ oracle price + tolerance: Execute swap normally.
- If pool price > oracle price + tolerance: Create limit order at oracle price + tolerance.

The Hook uses Uniswap V4 Hooks, TWAMM (Time-Weighted Average Market Making), Limit Orders and Eigenlayer AVS to enable these automations. Users have full control over these automations and can enable or disable them through the UI.

#### How do financial instruments benefit Web3 & NewEra Finance?

Unlike Web2 brokers, NewEra Finance offers users non-custodial investments that are transferable worldwide and tradable 24/7. This gives users complete control over their assets and minimizes counterparty risk.

NewEra Finance will offer RWAs across a wide range of categories, including Commodities, US Bonds, Global Bonds, Stocks, and ETFs. These assets are fractionalized, ownable, and globally accessible.

## Technical Overview

- **TWAMM** (Time-Weighted Average Market Making) for DCA with execution schedules.
- **Auto-Limit Order** functionality with Eigenlayer AVS price oracle integration.
- **Multi-Token** Selection & Swap via the Frontend.

### Architecture Diagram

![Architecture](Architecture-Diagram.png)

## Smart Hook Logic
This approach ensures that users receive automated execution, even in low liquidity markets by:
- Comparing the current market price against the oracle-provided actual RWA issurance/redemption price.
- Setting a user-defined tolerance level for premium.
- Executing immediately when the price is within the tolerance range.
- Creating a limit order at the maximum acceptable price when the current pool price exceeds the tolerance level.
- Automate time-based investments via DCA functionality.


## Technical Implementation
``` 

new-era-hookathon/
├── contracts/
│   ├── foundry.toml
│   ├── remappings.txt
│   ├── src/
│   │   ├── NewEraHook.sol
│   │   ├── interfaces/
│   │   ├── libraries/
│   │   └── types/
│   └── test/
│
├── frontend/
│   ├── public/
│   ├── src/
│   │   ├── abis/
│   │   ├── assets/
│   │   ├── components/
│   │   ├── connection/
│   │   ├── constants/
│   │   ├── context/
│   │   ├── featureFlags/
│   │   ├── graphql/
│   │   ├── hooks/
│   │   └── lib/
│   │   ├── ...
│   └── package.json
│
│── Execution_Service/
│   │── configs/
│   │── src/
│   │── Dockerfile
│   │── index.js
│   └── package.json
│ 
│── Validation_Service/
│       ├── configs/
│       ├── src/
│       ├── Dockerfile
│       ├── index.js
│       └── package.json
│
├── build/
│── grafana/
│── docker-compose.yml
│── prometheus.yaml
└── README.md

```


### Limit Order Integration for Auto-Limit Order

My implementation extends BaseHook and incorporates several key features:

- **EpochLibrary**: Implements epoch-based order tracking and lifecycle management
- **Hook Permissions**: Configured for `afterInitialize` and `afterSwap` operations
- **Order Lifecycle Management**: 
  - `place()`: Create new limit orders with Eigenlayer AVS RWA price + tolerance.
  - `kill()`: Cancel existing orders and return funds
  - `withdraw()`: Claim filled order proceeds
  - `_fillEpoch()`: Internal function to process orders when conditions are met

### TWAMM Integration for DCA

The Time-Weighted Average Market Making (TWAMM) functionality:
- Enables automated Dollar Cost Average (DCA) investment strategies.
- **TWAMM Order Lifecycle Management**:
- `submitOrder()`: Creates a new TWAMM order with specified tokens, expiration time, and amount
- `updateOrder()`: Modifies an existing TWAMM order's parameters
- `executeTWAMMOrders()`: Processes all active TWAMM orders since last execution
- `claimTokens()`: Allows users to claim proceeds from executed TWAMM orders


### Eigenlayer AVS Integration

My Smart Hook integrates with Eigenlayer AVS to retrieve the RWA underlying asset price (issuance/redemption price) in a trustless environment.



### Examples:

##### User 1
- Selects 3 RWAs via Multi-Token Swap.
- Sets Auto-Limit Order at 0.5% tolerance.
- Pool price is below 0.5% tolerance.
- Swap is executed against the pool, and the user receives 3 RWA tokens.


##### User 2
- Selects 3 RWAs via Multi-Token Swap.
- Sets Auto-Limit Order at 0.5% tolerance.
- Pool price exceeds 0.5% tolerance.
- Limit order is set at 0.5% above the oracle price.
- An arbitrage trader issues RWA tokens and fills the limit order position, and the user receives 3 RWA tokens.


##### User 3
- Selects 3 RWAs via Multi-Token Swap.
- Sets DCA expiry period of 5 minute.
- Split total Order Amount down into equal parts for sequential TWAMM execution over the 5-minute period.
- Sets Auto-Limit Order at 0.5% tolerance.
- The pool price is above 0.5% tolerance.
- Limit order is set at 0.5% above the oracle price.
- An arbitrage trader issues RWA tokens and fills the limit order position.
- The user receives 3 RWA tokens.


## Development Setup

To set up the development environment:

1. Clone the repository
```bash
# Clone the repository
git clone https://github.com/julian-newera/new-era-hookathon.git
cd new-era-hookathon/contracts

# Install dependencies
forge install

# Run all tests
forge test --via-ir
```

### Base Sepolia Environment

At https://stage.newera.finance/#/swap select Base-Sepolia Network

- NewEra Hook Contract: 0x3E86F8DEa5b8E4A36b4B93d8eB2A87A71CeC38C0

- AVS Attestation Center:
0x822BFc76e35C8bCcCeb5e10aC429F7EcE10D3416

- USDC ERC20 Contract: 0x60D7A23033f0e2Ebd4A509FF7a50d19AE3096007

- USDY ER20 Contract: 0xD446Ae173db30E2965010527D720b2539b350662

- PAXG ER20 Contract:
0x020dD0882F9132824bc3e5d539136D9BaacdFEd3

- bCSPX ER20 Contract: 0x6CCd3a7A28663D7997CdCA93796839683AB3dfD0

- DCA Transaction Proof:
[0x3c7c97cf66cf8437f84d4c707a0e2cdc9346853ccd0e519441aa5fd629b13bca](https://sepolia.basescan.org/tx/0x3c7c97cf66cf8437f84d4c707a0e2cdc9346853ccd0e519441aa5fd629b13bca)

- Limit Order Transaction Proof:
[0xa2319ee4bc606d915821509f9c9066aec811b3766ce5f0a279fc0aa3bced4b2b](https://sepolia.basescan.org/tx/0xa2319ee4bc606d915821509f9c9066aec811b3766ce5f0a279fc0aa3bced4b2b)


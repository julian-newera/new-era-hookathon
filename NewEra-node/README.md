# Price Oracle Integration

This project fetches commodity and public equity price data from an API and updates them on the blockchain using **TypeScript**, **ethers.js**, and **Axios**. It uses environment variables for configuration and supports batch updates for efficient contract interaction.

## Prerequisites

Before running the project, ensure that you have the following installed:

- **Node.js**: [Download and install Node.js](https://nodejs.org/)
- **npm**: Comes bundled with Node.js
- **MetaMask** or another Ethereum wallet with Sepolia testnet configured

### Environment Setup

Create a `.env` file in the project root with the following variables:
```
SEPOLIA_RPC=your_sepolia_rpc_url
PRIVATE_KEY=your_wallet_private_key
PRICE_ORACLE_ADDRESS=your_deployed_contract_address
```

### Install Dependencies

1. Clone the repository
2. Install the required dependencies:
   ```bash
   npm install
   ```

## Running the Scripts

### Commodity Price Updates
To update commodity prices:
```bash
ts-node getCommodityPrice.ts
```

### Public Equity Price Updates
To update public equity prices (with batch processing):
```bash
ts-node getPublicEquityPrice.ts
```

## Features

- Automated price fetching for commodities and public equities
- Batch processing for efficient contract updates
- Real-time price updates on Sepolia testnet
- Error handling and logging
- TypeScript type safety

## Contract Integration

The project interacts with a deployed PriceOracle contract that:
- Stores latest prices for multiple assets
- Supports batch updates for gas efficiency
- Maintains historical price data

## Error Handling

The scripts include comprehensive error handling for:
- API connection issues
- Invalid price data
- Blockchain transaction failures
- Environment variable validation
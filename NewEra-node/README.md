# Commodity Price Fetcher

This project fetches commodity price data from an API using **TypeScript** and **Axios**. It uses environment variables for configuration, and the data is retrieved via HTTP requests to the specified API.

## Prerequisites

Before running the project, ensure that you have the following installed:

- **Node.js**: [Download and install Node.js](https://nodejs.org/) if you haven’t already.
- **npm**: This comes bundled with Node.js, but you can check by running `npm -v` in your terminal.

### Install Dependencies

1. **Clone the repository** or download the project files.
2. Open a terminal and navigate to the project directory.
3. Install the required dependencies:
   ```bash
   npm install
```

## Running the Script

Option 1: Run Directly with ts-node
If you have ts-node installed globally or locally via npx, you can run the script directly:

1. Ensure that your .env file is set up correctly (with the BASE_URL).
2. In your terminal, run:
```bash
ts-node getCommodityPrice.ts
```
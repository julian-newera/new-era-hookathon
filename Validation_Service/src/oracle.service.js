require('dotenv').config();
const axios = require("axios");

// Token addresses - Update these with the correct addresses for your network
const TOKENS = {
  USDY: "0xD446Ae173db30E2965010527D720b2539b350662", // Add USDY token address
  USDC: "0x60D7A23033f0e2Ebd4A509FF7a50d19AE3096007", // USDC address
  PAXG: "0x020dD0882F9132824bc3e5d539136D9BaacdFEd3", // PAXG address
  bCSPX: "0xdd47689da802262Eaf822a94982d929c4afA16ce" // Add bCSPX token address
};

// Token pairs to monitor
const PAIRS = [
  { symbol: "USDYUSDC", base: "USDY", quote: "USDC" },
  { symbol: "PAXGUSDC", base: "PAXG", quote: "USDC" },
  { symbol: "bCSPXUSDC", base: "bCSPX", quote: "USDC" }
];

async function fetchPriceFromBybit(symbol) {
  try {
    const response = await axios.get(`https://api.bybit.com/v5/market/tickers?category=spot&symbol=${symbol}`);
    
    // Extract current price from ByBit response
    const tickerData = response.data.result.list[0];
    const price = parseFloat(tickerData.lastPrice);
    
    // Scale the price by 1e18 as expected by the contract
    const scaledPrice = BigInt(Math.floor(price * 1e18));
    
    console.log(`Fetched ${symbol} Price:`, price, "Scaled Price:", scaledPrice.toString());
    return scaledPrice;
  } catch (err) {
    console.error(`Error fetching ${symbol} price:`, err.message);
    return null;
  }
}

async function getAllPrices() {
  try {
    const pricePromises = PAIRS.map(async (pair) => {
      const price = await fetchPriceFromBybit(pair.symbol);
      if (price === null) return null;

      return {
        baseToken: TOKENS[pair.base],
        quoteToken: TOKENS[pair.quote],
        price: price,
        symbol: pair.symbol
      };
    });

    const prices = await Promise.all(pricePromises);
    return prices.filter(price => price !== null);
  } catch (err) {
    console.error("Error fetching prices:", err.message);
    return [];
  }
}

module.exports = {
  getAllPrices,
  TOKENS,
  PAIRS,
  fetchPriceFromBybit
};
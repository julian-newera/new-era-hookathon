require('dotenv').config();
const dalService = require("./dal.service");
const oracleService = require("./oracle.service");

async function validate(proofOfTask) {
  try {
    const taskResult = await dalService.getIPfsTask(proofOfTask);
    
    // Find the matching pair from our configuration
    const pair = oracleService.PAIRS.find(p => 
      p.baseToken === taskResult.baseToken && 
      p.quoteToken === taskResult.quoteToken
    );
    
    if (!pair) {
      console.error("Unknown token pair");
      return false;
    }

    // Fetch current price for validation
    const currentPrice = await oracleService.fetchPriceFromBybit(pair.symbol);
    if (currentPrice === null) return false;

    // Allow 1% deviation from the current price
    const upperBound = currentPrice * BigInt(101) / BigInt(100);
    const lowerBound = currentPrice * BigInt(99) / BigInt(100);
    
    const taskPrice = BigInt(taskResult.price);
    let isApproved = taskPrice <= upperBound && taskPrice >= lowerBound;
    
    return isApproved;
  } catch (err) {
    console.error(err?.message);
    return false;
  }
}
  
module.exports = {
  validate,
}
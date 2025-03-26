"use strict";
const oracleService = require("./oracle.service");
const dalService = require("./dal.service");
const { ethers } = require("ethers");

async function executeTask() {
    console.log("Executing price tasks.....");
    try {
        const allPrices = await oracleService.getAllPrices();
        
        for (const priceData of allPrices) {
            console.log(`Processing ${priceData.symbol}...`);
            
            const taskData = {
                baseToken: priceData.baseToken,
                quoteToken: priceData.quoteToken,
                price: priceData.price
            };

            const cid = await dalService.publishJSONToIpfs(taskData);
            
            // Encode the data as expected by the contract
            const encodedData = ethers.utils.defaultAbiCoder.encode(
                ["address", "address", "uint256"],
                [priceData.baseToken, priceData.quoteToken, priceData.price]
            );
            
            await dalService.sendTask(cid, encodedData, 0);
            console.log(`Submitted price for ${priceData.symbol}`);
        }
    } catch (error) {
        console.log(error)
    }
}

function start() {
    setTimeout(() => {
        executeTask(); 

        setInterval(() => {
            executeTask(); 
        }, 60 * 60 * 1000); 
    }, 10000); 
}

module.exports = { start };

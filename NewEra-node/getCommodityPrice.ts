import { fetchAssets, fetchAssetsClass } from './explorerPrice';
import { ethers } from 'ethers';
import cron from "node-cron";

import path from 'path';


// Load environment variables from .env file in the same directory
require("dotenv").config({ path: path.join(__dirname, '.env') });

// Define types for better type safety
interface CommodityData {
    name: string;
    price: number;
}

interface AssetClass {
    _id: string;
    name: string;
}

interface AssetClassResponse {
    isSuccess: boolean;
    assetClasses: AssetClass[];
}


async function getCommodityInfo(): Promise<CommodityData> {
    try {
        // Get the commodity ID from asset classes
        const response = await fetchAssetsClass() as AssetClassResponse;
        // console.log('Asset Classes:', response); // Debug log

        if (!response.isSuccess || !response.assetClasses) {
            throw new Error('Invalid asset classes response');
        }

        const commodityClass = response.assetClasses.find((ac: AssetClass) => ac.name === 'commodities');
        if (!commodityClass) {
            throw new Error('Commodity class not found');
        }

        const assetsResponse = await fetchAssets(commodityClass._id);

        if (!assetsResponse || !assetsResponse[0]) {
            throw new Error('No data received for the specified commodity');
        }

        const price = assetsResponse[0].price_dollar.val;
        const name = assetsResponse[0].name;

        // Validate price is a positive number
        if (typeof price !== 'number' || price <= 0) {
            throw new Error(`Invalid price received: ${price}`);
        }

        // Log the commodity data
        console.log(`Commodity Name: ${name}`);
        console.log(`Price in USD: $${price}`);

        return { 
            name, 
            price
        };
    } catch (error) {
        console.error('Error fetching commodity data:', error);
        throw error;
    }
}

async function updatePriceOracle(commodityData: CommodityData) {
    if (!process.env.PRICE_ORACLE_ADDRESS) {
        throw new Error('PRICE_ORACLE_ADDRESS environment variable is not set');
    }
    const oracleContract = process.env.PRICE_ORACLE_ADDRESS;
    try {
        // Connect to Sepolia network
        if (!process.env.SEPOLIA_RPC) {
            throw new Error('SEPOLIA_RPC environment variable is not set');
        }
        
        const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC);
        
        // Get the signer (you'll need to set up your private key in environment variables)
        const privateKey = process.env.PRIVATE_KEY;
        if (!privateKey) {
            throw new Error('PRIVATE_KEY environment variable is not set');
        }
        const signer = new ethers.Wallet(privateKey, provider);
       

        const priceOracle = new ethers.Contract(oracleContract, [
            "function updatePrices(string[] memory assets, uint256[] memory newPrices) external"
        ], signer);

        // Convert price to BigInt to handle large numbers
        const priceBigInt = BigInt(Math.floor(commodityData.price));

        // Log the data being sent
        // console.log('Sending to contract:');
        // console.log('Asset name:', commodityData.name);
        // console.log('Price:', priceBigInt.toString());

        // Call updatePrices function
        const tx = await priceOracle.updatePrices(
            [commodityData.name],
            [priceBigInt]
        );

        console.log(`Transaction hash: ${tx.hash}`);
        await tx.wait();
        console.log('Price updated successfully!');
    } catch (error) {
        console.error('Error updating price oracle:', error);
        throw error;
    }
}

// Example usage
async function main() {
    try {
        const commodityData = await getCommodityInfo();
        await updatePriceOracle(commodityData);
    } catch (error) {
        console.error('Failed to process commodity data:', error);
    }
}

// Execute if this file is run directly
if (require.main === module) {
    // Schedule to run every 20 minutes
    cron.schedule('*/5 * * * *', async () => {
        console.log('Running scheduled price update...');
        try {
            await main();
        } catch (error) {
            console.error('Scheduled update failed:', error);
        }
    });

    console.log('Price update service started. Will run every 20 minutes.');
}

export {
    getCommodityInfo,
    updatePriceOracle,
    type CommodityData
}; 
import { fetchAssets, fetchAssetsClass } from './explorerPrice';
import { ethers } from 'ethers';
import cron from "node-cron";
import path from 'path';

// Load environment variables from .env file in the same directory
require("dotenv").config({ path: path.join(__dirname, '.env') });

// Define types for better type safety
interface PublicEquityData {
    name: string;
    netAssetValue: number;
}

interface AssetClass {
    _id: string;
    name: string;
}

interface AssetClassResponse {
    isSuccess: boolean;
    assetClasses: AssetClass[];
}

async function getPublicEquityInfo(): Promise<PublicEquityData[]> {
    try {
        // Get the public equity ID from asset classes
        const response = await fetchAssetsClass() as AssetClassResponse;

        if (!response.isSuccess || !response.assetClasses) {
            throw new Error('Invalid asset classes response');
        }

        const publicEquityClass = response.assetClasses.find((ac: AssetClass) => ac.name === 'public_equity');
        if (!publicEquityClass) {
            throw new Error('Public equity class not found');
        }

        const assetsResponse = await fetchAssets(publicEquityClass._id);

        if (!assetsResponse || !Array.isArray(assetsResponse)) {
            throw new Error('No data received for public equity');
        }

        // Map through the assets array to extract name and net asset value
        const equityData = assetsResponse.map(asset => ({
            name: asset.name,
            netAssetValue: asset.net_asset_value_dollar?.val || 0
        }));

        // Log each asset's data
        // equityData.forEach(asset => {
        //     console.log(`Asset: ${asset.name}`);
        //     console.log(`Net Asset Value: $${asset.netAssetValue}`);
        //     console.log('---');
        // });

        return equityData;
    } catch (error) {
        console.error('Error fetching public equity data:', error);
        throw error;
    }
}


async function updatePriceOracle(publicEquityData: PublicEquityData[]) {
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
        
        // Get the signer
        const privateKey = process.env.PRIVATE_KEY;
        if (!privateKey) {
            throw new Error('PRIVATE_KEY environment variable is not set');
        }
        const signer = new ethers.Wallet(privateKey, provider);

        const priceOracle = new ethers.Contract(oracleContract, [
            "function updatePrices(string[] memory assets, uint256[] memory newPrices) external"
        ], signer);

        // Prepare arrays for batch update
        const names = publicEquityData.map(data => data.name);
        const prices = publicEquityData.map(data => BigInt(Math.floor(data.netAssetValue)));

        // Log the data being sent
        console.log('Sending to contract:');
        console.log('Asset names:', names);
        console.log('Prices:', prices.map(p => p.toString()));

        // Call updatePrices function with all data at once
        const tx = await priceOracle.updatePrices(names, prices);

        console.log(`Transaction hash: ${tx.hash}`);
        await tx.wait();
        console.log('All prices updated successfully!');
    } catch (error) {
        console.error('Error updating price oracle:', error);
        throw error;
    }
}

// Example usage
async function main() {
    try {
        const publicEquityData = await getPublicEquityInfo();
        await updatePriceOracle(publicEquityData);
    } catch (error) {
        console.error('Failed to process public equity data:', error);
    }
}

if (require.main === module) {
    // Schedule to run every 20 minutes
    // cron.schedule('*/20 * * * *', async () => {
        // console.log('Running scheduled price update...');
        // try {
            main();
        // } catch (error) {
            // console.error('Scheduled update failed:', error);
        // }
    // });

    console.log('Price update service started. Will run every 20 minutes.');
}

export {
    getPublicEquityInfo,
    type PublicEquityData
}; 
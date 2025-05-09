import { fetchAssets, fetchAssetsClass } from './explorerPrice';

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

// Example usage
async function main() {
    try {
        await getCommodityInfo();
    } catch (error) {
        console.error('Failed to process commodity data:', error);
    }
}

// Execute if this file is run directly
if (require.main === module) {
    main();
}

export {
    getCommodityInfo,
    type CommodityData
}; 
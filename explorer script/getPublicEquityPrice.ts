import { fetchAssets, fetchAssetsClass } from './explorerPrice';

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
        equityData.forEach(asset => {
            console.log(`Asset: ${asset.name}`);
            console.log(`Net Asset Value: $${asset.netAssetValue}`);
            console.log('---');
        });

        return equityData;
    } catch (error) {
        console.error('Error fetching public equity data:', error);
        throw error;
    }
}

// Example usage
async function main() {
    try {
        await getPublicEquityInfo();
    } catch (error) {
        console.error('Failed to process public equity data:', error);
    }
}

// Execute if this file is run directly
if (require.main === module) {
    main();
}

export {
    getPublicEquityInfo,
    type PublicEquityData
}; 
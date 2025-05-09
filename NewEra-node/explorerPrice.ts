// Import required dependencies
const axios = require("axios");
const path = require("path");

// Load environment variables from .env file in the same directory
require("dotenv").config({ path: path.join(__dirname, '.env') });

// Get BASE_URL from environment variables and remove any trailing slash
// This prevents double slashes in the API endpoints
const BASE_URL = process.env.BASE_URL?.replace(/\/$/, '');

// Validate that BASE_URL is set
if (!BASE_URL) {
    throw new Error('BASE_URL environment variable is not set. Please check your .env file.');
}

// Function to fetch all asset classes from the API
async function fetchAssetsClass() {
    try {
        const response = await axios.get(`${BASE_URL}/assets_class`);
        return response.data;
    } catch (error) {
        console.error('Error fetching assets:', error);
        throw error;
    }
}

// Function to fetch a specific asset by its ID
// @param id - The unique identifier of the asset to fetch
async function fetchAssets(id: string) {
    try {
        const response = await axios.get(`${BASE_URL}/assets/${id}`);
        return response.data.assets;
    } catch (error) {
        console.error('Error fetching asset price:', error);
        throw error;
    }
}

// Export the functions for use in other files
export {
    fetchAssetsClass,
    fetchAssets
};

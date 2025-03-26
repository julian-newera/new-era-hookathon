require('dotenv').config();
const axios = require("axios");

var ipfsHost='';

function init() {
  ipfsHost = process.env.IPFS_HOST;
}


async function getIPfsTask(cid) {
    const { data } = await axios.get(ipfsHost + cid);
    return {
        baseToken: data.baseToken,
        quoteToken: data.quoteToken,
        price: parseFloat(data.price)
    };
}  
  
module.exports = {
  init,
  getIPfsTask
}
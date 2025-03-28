// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/src/types/Currency.sol";

library PricingHelper {
    function priceToTick(uint256 _price, int24 tickSpacing) internal pure returns (int24) {
        int24 rawTick = int24(int256(_price / 1e16)) - int24(1e18 / 1e16);
        int24 tick = (rawTick / tickSpacing) * tickSpacing;
        return tick;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
} 
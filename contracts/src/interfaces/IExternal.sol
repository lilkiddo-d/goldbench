// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink AggregatorV3Interface (https://docs.robinhood.com/chain/oracles-and-price-feeds/)
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Optional Stock Token extensions documented at
///         https://docs.robinhood.com/chain/building-with-stock-tokens/ and .../oracles-and-price-feeds/
interface IStockToken {
    function oraclePaused() external view returns (bool);
    function uiMultiplier() external view returns (uint256);
}

/// @notice Uniswap SwapRouter02 (IV3SwapRouter) - no deadline field, deadline is enforced by the adapter.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

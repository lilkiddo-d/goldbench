// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price source. All prices are USD with 18 decimals per 1 whole token.
interface IOracleAdapter {
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt);
    function getRoundPrice(address asset, uint80 roundId) external view returns (uint256 price, uint256 updatedAt);
    function isSupported(address asset) external view returns (bool);
}

/// @notice Swappable execution venue. Pulls `amountIn` of `tokenIn` from msg.sender and sends output to `recipient`.
interface IDexAdapter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

interface IMarketClock {
    function isOpen(uint256 timestamp) external view returns (bool);
    function etDay(uint256 timestamp) external view returns (uint256);
    function lastCompletedSession(uint256 timestamp) external view returns (uint256 day);
    function isTradingDay(uint256 day) external view returns (bool);
    function closeTimestamp(uint256 day) external view returns (uint256);
}

interface IPriceHistory {
    function count(address asset) external view returns (uint256);
    function latestClose(address asset) external view returns (uint256);
    function lastDay(address asset) external view returns (uint256);
    function closeAt(address asset, uint256 ago) external view returns (uint256);
    function sma(address asset, uint256 window) external view returns (uint256);
    function median3(address asset) external view returns (uint256);
    function volatility(address asset, uint256 window) external view returns (uint256);
}

interface IComplianceRegistry {
    /// @param action keccak256 tag of the action, e.g. keccak256("DEPOSIT")
    function isAllowed(address account, bytes32 action) external view returns (bool);
}

interface ISignalEngine {
    struct Signal {
        bool riskOn;
        bool strongTrend;
        uint256 basketRatioLong; // 1e18 = basket exactly on its long MA
        uint256 basketRatioShort; // short MA / long MA, 1e18 scale
        uint256 basketVolBps; // annualised realised vol, bps
        uint256 goldRatioLong;
        uint256 goldVolBps;
        uint256 stockScaleBps; // 0..10000 fraction of each vault's stock cap to deploy
        uint256 goldShareBps; // share of the risk-off sleeve that goes to gold
        uint256 historyDays;
        uint256 timestamp;
    }

    function computeSignal() external view returns (Signal memory);
    function refreshSignal() external returns (Signal memory);
    function basket() external view returns (address[] memory assets, uint16[] memory weightsBps);
    function goldAsset() external view returns (address);
    function tbillAsset() external view returns (address);
    function setParam(uint8 id, uint256 value) external;
    function validateParam(uint8 id, uint256 value) external view;
}

interface IAllocator {
    function computeTargets(ISignalEngine.Signal calldata s, uint16 stockCapBps, uint16 bufferBps)
        external
        view
        returns (address[] memory assets, uint16[] memory weightsBps);
}

interface IFeeCollector {
    function distribute(address vault) external;
}

interface IProjectTokenHooks {
    function projectToken() external view returns (address);
    function totalStaked() external view returns (uint256);
    function notifyRebate(address vault, uint256 amount) external;
}

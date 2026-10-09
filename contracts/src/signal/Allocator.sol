// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAllocator, ISignalEngine} from "../interfaces/IGoldbench.sol";

/// @title Allocator
/// @notice Stateless translation of a Signal + vault stock cap into target portfolio weights (bps of NAV).
///         Output order: basket assets..., gold, tbill. The base asset (stablecoin) implicitly receives `bufferBps`.
///         Guarantee (fuzzed + invariant-tested): sum stock weights <= stockCapBps and sum weights + bufferBps = 10_000.
contract Allocator is IAllocator {
    ISignalEngine public immutable engine;

    error InvalidCap();

    constructor(ISignalEngine engine_) {
        engine = engine_;
    }

    function computeTargets(ISignalEngine.Signal calldata s, uint16 stockCapBps, uint16 bufferBps)
        external
        view
        returns (address[] memory assets, uint16[] memory weightsBps)
    {
        if (stockCapBps > 10_000 || bufferBps > 10_000) revert InvalidCap();
        (address[] memory basket, uint16[] memory bw) = engine.basket();
        uint256 n = basket.length;
        assets = new address[](n + 2);
        weightsBps = new uint16[](n + 2);

        uint256 investable = 10_000 - bufferBps;
        uint256 scale = s.stockScaleBps > 10_000 ? 10_000 : s.stockScaleBps;
        uint256 stocks = s.riskOn ? (uint256(stockCapBps) * scale) / 10_000 : 0;
        if (stocks > investable) stocks = investable;

        uint256 allocated = 0;
        for (uint256 i; i < n; ++i) {
            uint256 w = (stocks * bw[i]) / 10_000; // rounds down -> never exceeds cap
            assets[i] = basket[i];
            weightsBps[i] = uint16(w);
            allocated += w;
        }
        uint256 defensive = investable - allocated;
        uint256 goldShare = s.goldShareBps > 10_000 ? 10_000 : s.goldShareBps;
        uint256 gold = (defensive * goldShare) / 10_000;
        assets[n] = engine.goldAsset();
        weightsBps[n] = uint16(gold);
        assets[n + 1] = engine.tbillAsset();
        weightsBps[n + 1] = uint16(defensive - gold);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PriceHistory} from "../src/signal/PriceHistory.sol";
import {MarketClock} from "../src/market/MarketClock.sol";
import {ChainlinkOracleAdapter} from "../src/oracle/ChainlinkOracleAdapter.sol";
import {IAggregatorV3} from "../src/interfaces/IExternal.sol";

/// @title SeedHistory (one-time)
/// @notice Bootstraps PriceHistory from the Chainlink feeds' own on-chain round history so signals work on day one.
///         For every completed trading session it selects the last oracle round published before
///         `close + maxRecordDelay` — exactly what the live keeper would have recorded — and replays those round ids
///         through `PriceHistory.seedFromOracle`, which re-reads every price from the oracle (nothing is injected).
///         Must run (keeper account) before the first `recordDailyCloses`, which permanently closes seeding.
///
///   forge script script/SeedHistory.s.sol --rpc-url $RPC --account goldbench-keeper --broadcast
contract SeedHistory is Script {
    uint256 internal constant MAX_SCAN = 4000; // rounds per feed (all feeds are < 500 rounds as of 2026-10)
    uint256 internal constant SEED_SANITY = 3; // mirrors PriceHistory.SEED_SANITY_FACTOR

    function run() external {
        string memory json = vm.readFile(
            vm.envOr(
                "GOLDBENCH_DEPLOYMENT",
                string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json")
            )
        );
        PriceHistory h = PriceHistory(vm.parseJsonAddress(json, ".priceHistory"));
        address[] memory assets = h.assets();
        for (uint256 i; i < assets.length; ++i) {
            _seed(h, assets[i]);
        }
    }

    function _seed(PriceHistory h, address asset) internal {
        if (h.seedingClosed(asset)) {
            console2.log("seeding closed, skip", asset);
            return;
        }
        uint80[] memory ids = selectRounds(h, asset);
        console2.log("asset", asset, "sessions found", ids.length);
        uint256 batch = h.MAX_SEED_BATCH();
        for (uint256 start; start < ids.length; start += batch) {
            uint256 end = start + batch > ids.length ? ids.length : start + batch;
            uint80[] memory chunk = new uint80[](end - start);
            for (uint256 j = start; j < end; ++j) chunk[j - start] = ids[j];
            vm.broadcast();
            h.seedFromOracle(asset, chunk);
        }
        console2.log("  history count", h.count(asset));
    }

    struct Ctx {
        MarketClock clock;
        IAggregatorV3 feed;
        uint80 phaseBase;
        uint256 lastAllowed;
        uint256 delay;
        uint256 lastDay;
        uint256 live;
        uint256 scale; // 10 ** (18 - feed decimals)
    }

    /// @notice Public so it can be unit/fork tested without broadcasting.
    function selectRounds(PriceHistory h, address asset) public view returns (uint80[] memory ids) {
        Ctx memory c;
        c.clock = MarketClock(address(h.clock()));
        (c.feed,,,) = ChainlinkOracleAdapter(address(h.oracle())).feeds(asset);
        (uint80 latest,,,,) = c.feed.latestRoundData();
        c.phaseBase = (latest >> 64) << 64;
        c.lastAllowed = c.clock.lastCompletedSession(block.timestamp);
        c.delay = h.maxRecordDelay();
        c.lastDay = h.count(asset) == 0 ? 0 : h.lastDay(asset);
        (c.live,) = ChainlinkOracleAdapter(address(h.oracle())).getPrice(asset);
        c.scale = 10 ** (18 - uint256(c.feed.decimals()));

        uint64 aggLatest = uint64(latest);
        uint64 firstAgg = aggLatest > MAX_SCAN ? uint64(aggLatest - MAX_SCAN + 1) : 1;
        uint80[] memory tmp = new uint80[](aggLatest - firstAgg + 1);
        uint256 n;
        uint256 curDay;
        for (uint64 a = firstAgg; a <= aggLatest; ++a) {
            (uint80 id, uint256 day) = _eligible(c, a);
            if (day == 0) continue;
            if (n != 0 && day == curDay) {
                tmp[n - 1] = id; // later round for the same session wins
            } else {
                tmp[n++] = id;
                curDay = day;
            }
        }
        ids = new uint80[](n);
        for (uint256 i; i < n; ++i) ids[i] = tmp[i];
    }

    /// @return id the full proxy round id
    /// @return day New York session day the round represents, or 0 if the round is not usable
    function _eligible(Ctx memory c, uint64 agg) internal view returns (uint80 id, uint256 day) {
        id = c.phaseBase | uint80(agg);
        try c.feed.getRoundData(id) returns (uint80, int256 answer, uint256, uint256 ts, uint80) {
            if (ts == 0 || answer <= 0) return (id, 0);
            uint256 p = uint256(answer) * c.scale;
            if (p > c.live * SEED_SANITY || p * SEED_SANITY < c.live) return (id, 0); // e.g. mis-scaled launch rounds
            day = c.clock.etDay(ts);
            if (day <= c.lastDay || day > c.lastAllowed || !c.clock.isTradingDay(day)) return (id, 0);
            if (ts > c.clock.closeTimestamp(day) + c.delay) return (id, 0);
        } catch {
            return (id, 0);
        }
    }
}

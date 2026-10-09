// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IOracleAdapter, IMarketClock, IPriceHistory} from "../interfaces/IGoldbench.sol";

/// @title PriceHistory
/// @notice One daily close per US trading session per asset, stored in fixed-size (256) ring buffers.
///         Data only ever comes from the OracleAdapter (live `recordDailyCloses`, or historical oracle rounds for the
///         one-time `seedFromOracle`). Every stored close is clamped to +/-maxJumpBps of the previous close, so a single
///         bad print can move the series by at most that amount for a day; SignalEngine additionally uses the median of
///         the last three closes, so one outlier can never flip the regime.
contract PriceHistory is GoldbenchAccess, IPriceHistory {
    uint256 public constant CAPACITY = 256;
    uint256 public constant MAX_ASSETS = 8;
    uint256 public constant MAX_SEED_BATCH = 64;
    uint256 internal constant YEAR_TRADING_DAYS = 252;
    /// @dev Seeded historical rounds must lie within [live / 3, live x 3]. Real-world motivation: the first rounds of
    ///      the SPY and QQQ feeds on Robinhood Chain (2026-06-22/23) report prices ~1e8x too large.
    uint256 public constant SEED_SANITY_FACTOR = 3;

    struct Series {
        uint128[256] closes;
        uint64 lastDay;
        uint16 head;
        uint16 count;
        bool seedingClosed;
    }

    IOracleAdapter public oracle;
    IMarketClock public clock;
    uint16 public maxJumpBps = 1500; // bounds [500, 5000]
    uint32 public maxRecordDelay = 8 hours; // bounds [1h, 20h] after session close

    address[] internal _assets;
    mapping(address => bool) public tracked;
    mapping(address => Series) internal _series;

    event AssetAdded(address indexed asset);
    event OracleSet(address indexed oracle);
    event ClockSet(address indexed clock);
    event MaxJumpSet(uint16 bps);
    event MaxRecordDelaySet(uint32 delay);
    event CloseRecorded(address indexed asset, uint256 indexed day, uint256 rawPrice, uint256 storedPrice, bool clamped);
    event RecordSkipped(address indexed asset, uint256 indexed day, bytes reason);
    event SeedingClosed(address indexed asset);
    event SeedSkipped(address indexed asset, uint80 roundId, uint256 price, uint256 livePrice);
    event SeriesReset(address indexed asset);

    error TooManyAssets();
    error AlreadyTracked();
    error NotTracked(address asset);
    error SeedingIsClosed();
    error BatchTooLarge();
    error NonIncreasingDay(uint256 day, uint256 lastDay);
    error NotATradingSession(uint256 day);
    error OutsideRecordWindow(uint256 day);
    error InsufficientHistory(uint256 have, uint256 need);
    error ZeroWindow();

    constructor(address admin, IOracleAdapter oracle_, IMarketClock clock_) GoldbenchAccess(admin) {
        if (address(oracle_) == address(0) || address(clock_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        clock = clock_;
        emit OracleSet(address(oracle_));
        emit ClockSet(address(clock_));
    }

    // ----------------------------- admin -----------------------------

    function addAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (tracked[asset]) revert AlreadyTracked();
        if (_assets.length >= MAX_ASSETS) revert TooManyAssets();
        tracked[asset] = true;
        _assets.push(asset);
        emit AssetAdded(asset);
    }

    function setOracle(IOracleAdapter o) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(o) == address(0)) revert ZeroAddress();
        oracle = o;
        emit OracleSet(address(o));
    }

    function setClock(IMarketClock c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(c) == address(0)) revert ZeroAddress();
        clock = c;
        emit ClockSet(address(c));
    }

    function setMaxJumpBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(bps, 500, 5000);
        maxJumpBps = bps;
        emit MaxJumpSet(bps);
    }

    function setMaxRecordDelay(uint32 d) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(d, 1 hours, 20 hours);
        maxRecordDelay = d;
        emit MaxRecordDelaySet(d);
    }

    // ----------------------------- recording -----------------------------

    /// @notice Record today's close for every tracked asset. Must be called within `maxRecordDelay` of the session
    ///         close. Assets whose oracle read fails are skipped (event) rather than blocking the others.
    // slither-disable-next-line unused-return
    function recordDailyCloses() external onlyRole(KEEPER_ROLE) whenNotPaused returns (uint256 day) {
        day = clock.lastCompletedSession(block.timestamp);
        uint256 closeTs = clock.closeTimestamp(day);
        if (block.timestamp > closeTs + maxRecordDelay) revert OutsideRecordWindow(day);
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            address a = _assets[i];
            Series storage s = _series[a];
            if (s.count != 0 && s.lastDay >= day) continue;
            // updatedAt is already bounded by the adapter's staleness check
            try oracle.getPrice(a) returns (uint256 p, uint256) {
                if (!s.seedingClosed) {
                    s.seedingClosed = true;
                    emit SeedingClosed(a);
                }
                _push(a, s, day, p);
            } catch (bytes memory reason) {
                emit RecordSkipped(a, day, reason);
            }
        }
    }

    /// @notice One-time bootstrap so signals work on day one: replay historical oracle rounds (oldest first).
    ///         The keeper only chooses *which* signed oracle round represents each day; prices cannot be injected.
    // slither-disable-next-line unused-return
    function seedFromOracle(address asset, uint80[] calldata roundIds) external onlyRole(KEEPER_ROLE) {
        if (!tracked[asset]) revert NotTracked(asset);
        if (roundIds.length > MAX_SEED_BATCH) revert BatchTooLarge();
        Series storage s = _series[asset];
        if (s.seedingClosed) revert SeedingIsClosed();
        uint256 latestAllowed = clock.lastCompletedSession(block.timestamp);
        (uint256 live,) = oracle.getPrice(asset); // live, staleness-checked reference for the sanity band
        for (uint256 i; i < roundIds.length; ++i) {
            (uint256 p, uint256 ts) = oracle.getRoundPrice(asset, roundIds[i]);
            if (p > live * SEED_SANITY_FACTOR || p * SEED_SANITY_FACTOR < live) {
                emit SeedSkipped(asset, roundIds[i], p, live);
                continue;
            }
            uint256 day = clock.etDay(ts);
            if (s.count != 0 && day <= s.lastDay) revert NonIncreasingDay(day, s.lastDay);
            if (day > latestAllowed) revert NonIncreasingDay(day, latestAllowed);
            if (!clock.isTradingDay(day)) revert NotATradingSession(day);
            _push(asset, s, day, p);
        }
    }

    /// @notice Timelock-only recovery for a series poisoned before any safeguard could act (e.g. a bad first print).
    ///         Clears the ring buffer and re-opens seeding. 48h-delayed, so it cannot be used to game a rebalance.
    function resetSeries(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!tracked[asset]) revert NotTracked(asset);
        Series storage s = _series[asset];
        s.head = 0;
        s.count = 0;
        s.lastDay = 0;
        s.seedingClosed = false;
        emit SeriesReset(asset);
    }

    function closeSeeding(address asset) external onlyRole(KEEPER_ROLE) {
        if (!tracked[asset]) revert NotTracked(asset);
        _series[asset].seedingClosed = true;
        emit SeedingClosed(asset);
    }

    function _push(address asset, Series storage s, uint256 day, uint256 raw) internal {
        uint256 stored = raw;
        bool clamped = false;
        if (s.count != 0) {
            uint256 last = s.closes[s.head];
            uint256 band = (last * maxJumpBps) / 10_000;
            if (raw > last + band) {
                stored = last + band;
                clamped = true;
            } else if (raw + band < last) {
                stored = last - band;
                clamped = true;
            }
            s.head = uint16((uint256(s.head) + 1) % CAPACITY);
        }
        s.closes[s.head] = uint128(stored);
        if (s.count < CAPACITY) s.count += 1;
        s.lastDay = uint64(day);
        emit CloseRecorded(asset, day, raw, stored, clamped);
    }

    // ----------------------------- views -----------------------------

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function count(address asset) external view returns (uint256) {
        return _series[asset].count;
    }

    function lastDay(address asset) external view returns (uint256) {
        return _series[asset].lastDay;
    }

    function seedingClosed(address asset) external view returns (bool) {
        return _series[asset].seedingClosed;
    }

    function latestClose(address asset) external view returns (uint256) {
        Series storage s = _series[asset];
        if (s.count == 0) return 0;
        return s.closes[s.head];
    }

    /// @param ago 0 = most recent close
    function closeAt(address asset, uint256 ago) public view returns (uint256) {
        Series storage s = _series[asset];
        if (ago >= s.count) revert InsufficientHistory(s.count, ago + 1);
        return s.closes[(uint256(s.head) + CAPACITY - ago) % CAPACITY];
    }

    /// @notice Most recent `n` closes, newest first (for the frontend chart).
    function recentCloses(address asset, uint256 n) external view returns (uint256[] memory out) {
        Series storage s = _series[asset];
        if (n > s.count) n = s.count;
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = s.closes[(uint256(s.head) + CAPACITY - i) % CAPACITY];
        }
    }

    function sma(address asset, uint256 window) external view returns (uint256) {
        Series storage s = _series[asset];
        if (window == 0) revert ZeroWindow();
        if (window > s.count) revert InsufficientHistory(s.count, window);
        uint256 sum = 0;
        uint256 h = s.head;
        for (uint256 i; i < window; ++i) {
            sum += s.closes[(h + CAPACITY - i) % CAPACITY];
        }
        return sum / window;
    }

    /// @notice Median of the last three closes (single-outlier robust spot used by the signal).
    function median3(address asset) external view returns (uint256) {
        Series storage s = _series[asset];
        if (s.count == 0) revert InsufficientHistory(0, 1);
        if (s.count < 3) return s.closes[s.head];
        uint256 a = closeAt(asset, 0);
        uint256 b = closeAt(asset, 1);
        uint256 c = closeAt(asset, 2);
        return Math.max(Math.min(a, b), Math.min(Math.max(a, b), c));
    }

    /// @notice Annualised (sqrt252) sample standard deviation of `window` daily simple returns, in bps.
    function volatility(address asset, uint256 window) external view returns (uint256) {
        Series storage s = _series[asset];
        if (window < 2) revert ZeroWindow();
        if (window + 1 > s.count) revert InsufficientHistory(s.count, window + 1);
        int256[] memory r = new int256[](window);
        int256 sum = 0;
        uint256 h = s.head;
        for (uint256 i; i < window; ++i) {
            int256 p0 = int256(uint256(s.closes[(h + CAPACITY - i - 1) % CAPACITY]));
            int256 p1 = int256(uint256(s.closes[(h + CAPACITY - i) % CAPACITY]));
            r[i] = ((p1 - p0) * 1e18) / p0;
            sum += r[i];
        }
        int256 mean = sum / int256(window);
        uint256 ss = 0;
        for (uint256 i; i < window; ++i) {
            int256 d = r[i] - mean;
            ss += uint256(d * d);
        }
        uint256 annual = Math.sqrt((ss * YEAR_TRADING_DAYS) / (window - 1)); // sample variance x 252, 1e18 scale
        return (annual * 10_000) / 1e18;
    }
}

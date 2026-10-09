// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IOracleAdapter} from "../interfaces/IGoldbench.sol";
import {IAggregatorV3, IStockToken} from "../interfaces/IExternal.sol";

/// @title ChainlinkOracleAdapter
/// @notice Reads Chainlink AggregatorV3 feeds and normalises to 1e18 USD per whole token.
///         Guards: positive answer, completed round, per-asset staleness bound, optional L2 sequencer uptime feed with
///         grace period, and the Stock Token `oraclePaused()` advisory flag (corporate actions).
///         Deviation (single-print outlier) filtering lives in PriceHistory / RotationVault where a reference exists.
///         Swappable: vaults and PriceHistory hold an IOracleAdapter address that the Timelock can replace.
contract ChainlinkOracleAdapter is GoldbenchAccess, IOracleAdapter {
    struct FeedConfig {
        IAggregatorV3 feed;
        uint32 maxStaleness;
        uint8 decimals;
        bool checkTokenPause;
    }

    uint32 public constant MIN_STALENESS = 1 hours;
    uint32 public constant MAX_STALENESS = 4 days;
    uint32 public constant MAX_GRACE = 1 days;

    mapping(address asset => FeedConfig) public feeds;
    IAggregatorV3 public sequencerUptimeFeed; // address(0) = no feed published for this chain (documented gap)
    uint32 public sequencerGracePeriod = 1 hours;

    event FeedSet(address indexed asset, address indexed feed, uint32 maxStaleness, uint8 decimals, bool checkTokenPause);
    event SequencerFeedSet(address indexed feed, uint32 gracePeriod);

    error UnsupportedAsset(address asset);
    error InvalidPrice(address asset, int256 answer);
    error StalePrice(address asset, uint256 updatedAt);
    error OraclePausedByIssuer(address asset);
    error SequencerDown();
    error SequencerGracePeriod();
    error RoundIncomplete(address asset, uint80 roundId);

    constructor(address admin) GoldbenchAccess(admin) {}

    function setFeed(address asset, address feed, uint32 maxStaleness, bool checkTokenPause)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        _checkBounds(maxStaleness, MIN_STALENESS, MAX_STALENESS);
        uint8 dec = IAggregatorV3(feed).decimals();
        _checkBounds(dec, 0, 36);
        feeds[asset] = FeedConfig(IAggregatorV3(feed), maxStaleness, dec, checkTokenPause);
        emit FeedSet(asset, feed, maxStaleness, dec, checkTokenPause);
    }

    function setSequencerFeed(address feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkBounds(gracePeriod, 0, MAX_GRACE);
        sequencerUptimeFeed = IAggregatorV3(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    function isSupported(address asset) external view returns (bool) {
        return address(feeds[asset].feed) != address(0);
    }

    /// @inheritdoc IOracleAdapter
    // slither-disable-next-line unused-return
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt) {
        FeedConfig memory c = _config(asset);
        _checkSequencer();
        if (c.checkTokenPause) _checkTokenPause(asset);
        // roundId/startedAt/answeredInRound are deprecated by Chainlink; answer + updatedAt are validated below
        (, int256 answer,, uint256 ts,) = c.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset, answer);
        if (ts == 0 || ts > block.timestamp) revert StalePrice(asset, ts);
        if (block.timestamp - ts > c.maxStaleness) revert StalePrice(asset, ts);
        return (_scale(uint256(answer), c.decimals), ts);
    }

    /// @notice Historical round, used only to seed PriceHistory from the oracle itself (no off-chain trust).
    // slither-disable-next-line unused-return
    function getRoundPrice(address asset, uint80 roundId) external view returns (uint256 price, uint256 updatedAt) {
        FeedConfig memory c = _config(asset);
        (, int256 answer,, uint256 ts,) = c.feed.getRoundData(roundId);
        if (answer <= 0) revert InvalidPrice(asset, answer);
        if (ts == 0 || ts > block.timestamp) revert RoundIncomplete(asset, roundId);
        return (_scale(uint256(answer), c.decimals), ts);
    }

    function _config(address asset) internal view returns (FeedConfig memory c) {
        c = feeds[asset];
        if (address(c.feed) == address(0)) revert UnsupportedAsset(asset);
    }

    // slither-disable-next-line unused-return
    function _checkSequencer() internal view {
        IAggregatorV3 f = sequencerUptimeFeed;
        if (address(f) == address(0)) return;
        (, int256 status, uint256 startedAt,,) = f.latestRoundData();
        if (status != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod();
    }

    function _checkTokenPause(address asset) internal view {
        // Advisory flag documented by the issuer; tolerate tokens that do not implement it.
        try IStockToken(asset).oraclePaused() returns (bool paused) {
            if (paused) revert OraclePausedByIssuer(asset);
        } catch {}
    }

    function _scale(uint256 v, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return v;
        if (dec < 18) return v * 10 ** (18 - dec);
        return v / 10 ** (dec - 18);
    }
}

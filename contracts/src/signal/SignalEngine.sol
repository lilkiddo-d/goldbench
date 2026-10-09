// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IPriceHistory, ISignalEngine} from "../interfaces/IGoldbench.sol";

/// @title SignalEngine
/// @notice Trend + volatility regime model computed purely from PriceHistory daily closes.
///
///   spot_i        = median of the last 3 closes            (one bad print cannot move it)
///   ratioLong     = sum w_i * spot_i / SMA_long_i             (basket vs its 200-day MA, 1e18 = on the MA)
///   ratioShort    = sum w_i * SMA_short_i / SMA_long_i        (50/200 "golden cross" strength)
///   vol           = sum w_i * realisedVol_i(volWindow)        (annualised, bps)
///
///   regime        risk-on  if ratioLong > 1 + hysteresis
///                 risk-off if ratioLong < 1 - hysteresis
///                 unchanged otherwise (prevents whipsaw)
///   stockScale    = riskOn ? trendScale * clamp(targetVol / vol, minVolScale, 1) : 0
///                   trendScale = 1 if ratioShort >= 1 else weakTrendScale
///   goldShare     = gold spot > gold SMA_long ? goldShareOn : goldShareOff   (split of the risk-off sleeve)
///                   (neutral midpoint while the gold series has < minHistory closes)
///
/// Warm-up: until 200 closes exist, SMA_long uses all available closes (requires >= minHistory for the basket).
///
/// Every parameter is changeable only by DEFAULT_ADMIN_ROLE (the 48h Timelock, which may be fed by staker votes)
/// and only inside hard-coded bounds.
contract SignalEngine is GoldbenchAccess, ISignalEngine {
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    /// @dev Admin of VAULT_ROLE; granted to the VaultFactory so new vaults can commit signals.
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    uint8 public constant P_MA_LONG = 0;
    uint8 public constant P_MA_SHORT = 1;
    uint8 public constant P_VOL_WINDOW = 2;
    uint8 public constant P_TARGET_VOL_BPS = 3;
    uint8 public constant P_MIN_VOL_SCALE_BPS = 4;
    uint8 public constant P_HYSTERESIS_BPS = 5;
    uint8 public constant P_WEAK_TREND_SCALE_BPS = 6;
    uint8 public constant P_GOLD_SHARE_ON_BPS = 7;
    uint8 public constant P_GOLD_SHARE_OFF_BPS = 8;
    uint8 public constant P_MIN_HISTORY = 9;
    uint8 public constant PARAM_COUNT = 10;

    uint256 public constant MAX_BASKET = 4;

    IPriceHistory public history;
    uint256[10] internal _params;

    address[] internal _basket;
    uint16[] internal _weights;
    address public goldAsset;
    address public tbillAsset;

    bool public riskOnState; // hysteresis memory; starts risk-off (conservative)

    event ParamUpdated(uint8 indexed id, uint256 oldValue, uint256 newValue);
    event BasketSet(address[] assets, uint16[] weightsBps);
    event DefensiveAssetsSet(address gold, address tbill);
    event HistorySet(address history);
    event SignalRefreshed(
        bool riskOn,
        bool strongTrend,
        uint256 basketRatioLong,
        uint256 basketRatioShort,
        uint256 basketVolBps,
        uint256 goldRatioLong,
        uint256 goldVolBps,
        uint256 stockScaleBps,
        uint256 goldShareBps,
        uint256 historyDays
    );

    error UnknownParam(uint8 id);
    error InvalidBasket();
    error InsufficientHistory(uint256 have, uint256 need);
    error InconsistentParams();

    constructor(address admin, IPriceHistory history_) GoldbenchAccess(admin) {
        if (address(history_) == address(0)) revert ZeroAddress();
        history = history_;
        _setRoleAdmin(VAULT_ROLE, REGISTRAR_ROLE);
        _params[P_MA_LONG] = 200;
        _params[P_MA_SHORT] = 50;
        _params[P_VOL_WINDOW] = 20;
        _params[P_TARGET_VOL_BPS] = 1500;
        _params[P_MIN_VOL_SCALE_BPS] = 2500;
        _params[P_HYSTERESIS_BPS] = 100;
        _params[P_WEAK_TREND_SCALE_BPS] = 5000;
        _params[P_GOLD_SHARE_ON_BPS] = 6000;
        _params[P_GOLD_SHARE_OFF_BPS] = 2000;
        _params[P_MIN_HISTORY] = 50;
        emit HistorySet(address(history_));
    }

    // ----------------------------- bounds -----------------------------

    function bounds(uint8 id) public pure returns (uint256 min, uint256 max) {
        if (id == P_MA_LONG) return (100, 250);
        if (id == P_MA_SHORT) return (10, 100);
        if (id == P_VOL_WINDOW) return (10, 60);
        if (id == P_TARGET_VOL_BPS) return (500, 4000);
        if (id == P_MIN_VOL_SCALE_BPS) return (0, 10_000);
        if (id == P_HYSTERESIS_BPS) return (0, 500);
        if (id == P_WEAK_TREND_SCALE_BPS) return (0, 10_000);
        if (id == P_GOLD_SHARE_ON_BPS) return (0, 10_000);
        if (id == P_GOLD_SHARE_OFF_BPS) return (0, 10_000);
        if (id == P_MIN_HISTORY) return (30, 250);
        revert UnknownParam(id);
    }

    /// @notice Reverts if `value` is outside hard bounds or would make the parameter set inconsistent.
    function validateParam(uint8 id, uint256 value) public view {
        (uint256 min, uint256 max) = bounds(id);
        _checkBounds(value, min, max);
        uint256[10] memory p = _params;
        p[id] = value;
        if (p[P_MA_SHORT] >= p[P_MA_LONG]) revert InconsistentParams();
        if (p[P_MIN_HISTORY] <= p[P_VOL_WINDOW] || p[P_MIN_HISTORY] < p[P_MA_SHORT] || p[P_MIN_HISTORY] > p[P_MA_LONG]) {
            revert InconsistentParams();
        }
    }

    function setParam(uint8 id, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validateParam(id, value);
        emit ParamUpdated(id, _params[id], value);
        _params[id] = value;
    }

    function param(uint8 id) external view returns (uint256) {
        if (id >= PARAM_COUNT) revert UnknownParam(id);
        return _params[id];
    }

    function params() external view returns (uint256[10] memory) {
        return _params;
    }

    // ----------------------------- config -----------------------------

    function setBasket(address[] calldata assets, uint16[] calldata weightsBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 n = assets.length;
        if (n == 0 || n > MAX_BASKET || n != weightsBps.length) revert InvalidBasket();
        uint256 sum = 0;
        for (uint256 i; i < n; ++i) {
            if (assets[i] == address(0) || weightsBps[i] == 0) revert InvalidBasket();
            for (uint256 j; j < i; ++j) {
                if (assets[j] == assets[i]) revert InvalidBasket();
            }
            sum += weightsBps[i];
        }
        if (sum != 10_000) revert InvalidBasket();
        _basket = assets;
        _weights = weightsBps;
        emit BasketSet(assets, weightsBps);
    }

    function setDefensiveAssets(address gold, address tbill) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gold == address(0) || tbill == address(0) || gold == tbill) revert ZeroAddress();
        goldAsset = gold;
        tbillAsset = tbill;
        emit DefensiveAssetsSet(gold, tbill);
    }

    function setHistory(IPriceHistory h) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(h) == address(0)) revert ZeroAddress();
        history = h;
        emit HistorySet(address(h));
    }

    function basket() external view returns (address[] memory, uint16[] memory) {
        return (_basket, _weights);
    }

    // ----------------------------- signal -----------------------------

    function computeSignal() public view returns (Signal memory s) {
        uint256 n = _basket.length;
        if (n == 0 || goldAsset == address(0)) revert InvalidBasket();

        uint256 have = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            have = Math.min(have, history.count(_basket[i]));
        }
        uint256 minHist = _params[P_MIN_HISTORY];
        if (have < minHist) revert InsufficientHistory(have, minHist);

        uint256 longW = Math.min(_params[P_MA_LONG], have);
        uint256 shortW = Math.min(_params[P_MA_SHORT], longW);
        uint256 volW = _params[P_VOL_WINDOW];

        for (uint256 i; i < n; ++i) {
            address a = _basket[i];
            uint256 w = _weights[i];
            uint256 maL = history.sma(a, longW);
            s.basketRatioLong += (w * history.median3(a) * 1e18) / maL / 10_000;
            s.basketRatioShort += (w * history.sma(a, shortW) * 1e18) / maL / 10_000;
            s.basketVolBps += (w * history.volatility(a, volW)) / 10_000;
        }
        // Gold trend only steers the split *inside* the risk-off sleeve. A young gold feed (less than minHistory
        // closes) yields a neutral split instead of blocking the whole engine; goldRatioLong = 0 flags "warming up".
        uint256 goldHave = history.count(goldAsset);
        bool goldReady = goldHave >= minHist;
        if (goldReady) {
            uint256 goldLongW = Math.min(_params[P_MA_LONG], goldHave);
            s.goldRatioLong = (history.median3(goldAsset) * 1e18) / history.sma(goldAsset, goldLongW);
            s.goldVolBps = history.volatility(goldAsset, volW);
        }

        uint256 h = (_params[P_HYSTERESIS_BPS] * 1e18) / 10_000;
        if (s.basketRatioLong > 1e18 + h) s.riskOn = true;
        else if (s.basketRatioLong + h < 1e18) s.riskOn = false;
        else s.riskOn = riskOnState;

        s.strongTrend = s.basketRatioShort >= 1e18;
        if (s.riskOn) {
            uint256 trend = s.strongTrend ? 10_000 : _params[P_WEAK_TREND_SCALE_BPS];
            uint256 volScale = s.basketVolBps == 0 ? 10_000 : (_params[P_TARGET_VOL_BPS] * 10_000) / s.basketVolBps;
            volScale = Math.min(10_000, Math.max(volScale, _params[P_MIN_VOL_SCALE_BPS]));
            s.stockScaleBps = (trend * volScale) / 10_000;
        }
        if (!goldReady) {
            s.goldShareBps = (_params[P_GOLD_SHARE_ON_BPS] + _params[P_GOLD_SHARE_OFF_BPS]) / 2;
        } else {
            s.goldShareBps = s.goldRatioLong > 1e18 ? _params[P_GOLD_SHARE_ON_BPS] : _params[P_GOLD_SHARE_OFF_BPS];
        }
        s.historyDays = have;
        s.timestamp = block.timestamp;
    }

    /// @notice Called by vaults when starting a rebalance; commits hysteresis state and emits the full signal.
    function refreshSignal() external onlyRole(VAULT_ROLE) returns (Signal memory s) {
        s = computeSignal();
        riskOnState = s.riskOn;
        emit SignalRefreshed(
            s.riskOn,
            s.strongTrend,
            s.basketRatioLong,
            s.basketRatioShort,
            s.basketVolBps,
            s.goldRatioLong,
            s.goldVolBps,
            s.stockScaleBps,
            s.goldShareBps,
            s.historyDays
        );
    }
}

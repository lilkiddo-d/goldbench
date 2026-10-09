// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IMarketClock} from "../interfaces/IGoldbench.sol";

/// @title MarketClock
/// @notice US regular-session clock (09:30-16:00 America/New_York, Mon-Fri) with on-chain US DST rules
///         (2nd Sunday of March 02:00 local -> 1st Sunday of November 02:00 local), an admin-maintained holiday
///         calendar and early closes. The guardian may add *emergency closures* only (it can never open the market).
///         "Days" are America/New_York calendar days counted from 1970-01-01.
contract MarketClock is GoldbenchAccess, IMarketClock {
    uint256 internal constant DAY = 1 days;
    uint16 public constant OPEN_MINUTE = 9 * 60 + 30;
    uint16 public constant CLOSE_MINUTE = 16 * 60;
    uint256 public constant MAX_BATCH = 32;
    uint256 internal constant LOOKBACK = 12;

    mapping(uint256 day => bool) public isHoliday;
    mapping(uint256 day => uint16 minute) public earlyClose;

    event HolidaySet(uint256 indexed day, bool closed);
    event EarlyCloseSet(uint256 indexed day, uint16 closeMinute);

    error BatchTooLarge();
    error NoRecentSession();

    constructor(address admin) GoldbenchAccess(admin) {}

    // ----------------------------- admin -----------------------------

    function setHolidays(uint256[] calldata days_, bool closed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (days_.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < days_.length; ++i) {
            isHoliday[days_[i]] = closed;
            emit HolidaySet(days_[i], closed);
        }
    }

    /// @notice Guardian can declare an unscheduled closure (e.g. national day of mourning). It can never re-open.
    function emergencyClose(uint256 day) external onlyRole(GUARDIAN_ROLE) {
        isHoliday[day] = true;
        emit HolidaySet(day, true);
    }

    function setEarlyClose(uint256 day, uint16 closeMinute) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (closeMinute != 0) _checkBounds(closeMinute, OPEN_MINUTE + 1, CLOSE_MINUTE);
        earlyClose[day] = closeMinute;
        emit EarlyCloseSet(day, closeMinute);
    }

    // ----------------------------- views -----------------------------

    function isOpen(uint256 ts) external view returns (bool) {
        uint256 day = etDay(ts);
        if (!isTradingDay(day)) return false;
        uint256 local = ts - _offset(ts) - day * DAY;
        return local >= uint256(OPEN_MINUTE) * 60 && local < uint256(closeMinuteOf(day)) * 60;
    }

    function etDay(uint256 ts) public pure returns (uint256) {
        return (ts - _offset(ts)) / DAY;
    }

    function isTradingDay(uint256 day) public view returns (bool) {
        uint256 wd = weekday(day);
        return wd >= 1 && wd <= 5 && !isHoliday[day];
    }

    function closeMinuteOf(uint256 day) public view returns (uint16) {
        uint16 e = earlyClose[day];
        return e == 0 ? CLOSE_MINUTE : e;
    }

    /// @notice UTC timestamp of the session close for an ET day.
    function closeTimestamp(uint256 day) public view returns (uint256) {
        uint256 noonUtcApprox = day * DAY + 17 hours; // 12:00 ET is 16:00/17:00 UTC: safely inside the same DST regime
        return day * DAY + uint256(closeMinuteOf(day)) * 60 + _offset(noonUtcApprox);
    }

    /// @notice Most recent trading day whose session has fully closed at `ts`.
    function lastCompletedSession(uint256 ts) external view returns (uint256) {
        uint256 d = etDay(ts);
        for (uint256 i; i < LOOKBACK; ++i) {
            if (d < i) break;
            uint256 day = d - i;
            if (isTradingDay(day) && ts >= closeTimestamp(day)) return day;
        }
        revert NoRecentSession();
    }

    // ----------------------------- calendar math -----------------------------

    /// @dev 0 = Sunday ... 6 = Saturday (1970-01-01 was a Thursday).
    function weekday(uint256 day) public pure returns (uint256) {
        return (day + 4) % 7;
    }

    function isDST(uint256 ts) public pure returns (bool) {
        (uint256 y,,) = civilFromDays(ts / DAY);
        uint256 start = nthSunday(y, 3, 2) * DAY + 7 hours; // 02:00 EST = 07:00 UTC
        uint256 end = nthSunday(y, 11, 1) * DAY + 6 hours; // 02:00 EDT = 06:00 UTC
        return ts >= start && ts < end;
    }

    function nthSunday(uint256 y, uint256 m, uint256 n) public pure returns (uint256) {
        uint256 first = daysFromCivil(y, m, 1);
        uint256 firstSunday = first + (7 - weekday(first)) % 7;
        return firstSunday + 7 * (n - 1);
    }

    // Integer calendar arithmetic: truncating divisions are the algorithm, not a precision bug.
    // slither-disable-start divide-before-multiply
    /// @dev Howard Hinnant's days_from_civil, valid for years >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    function civilFromDays(uint256 z) public pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
    // slither-disable-end divide-before-multiply

    function _offset(uint256 ts) internal pure returns (uint256) {
        return isDST(ts) ? 4 hours : 5 hours;
    }
}

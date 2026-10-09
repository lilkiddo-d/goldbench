// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketClock} from "../../src/market/MarketClock.sol";
import {GoldbenchAccess} from "../../src/access/GoldbenchAccess.sol";

contract MarketClockTest is Test {
    MarketClock clock;
    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");

    function setUp() public {
        clock = new MarketClock(admin);
        bytes32 g = clock.GUARDIAN_ROLE();
        vm.prank(admin);
        clock.grantRole(g, guardian);
    }

    function test_calendarMath() public view {
        assertEq(clock.daysFromCivil(1970, 1, 1), 0);
        assertEq(clock.daysFromCivil(2026, 10, 7), 20733);
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(20733);
        assertEq(y, 2026);
        assertEq(m, 10);
        assertEq(d, 7);
        (y, m, d) = clock.civilFromDays(clock.daysFromCivil(2028, 2, 29));
        assertEq(y * 10000 + m * 100 + d, 20280229);
        assertEq(clock.weekday(20733), 3); // Wednesday
        assertEq(clock.nthSunday(2026, 3, 2), 20520); // 2026-03-08
        assertEq(clock.nthSunday(2026, 11, 1), 20758); // 2026-11-01
    }

    function testFuzz_civilRoundTrip(uint256 day) public view {
        day = bound(day, 0, 200_000);
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(day);
        assertEq(clock.daysFromCivil(y, m, d), day);
    }

    function test_dstBoundaries() public view {
        assertFalse(clock.isDST(1772953199));
        assertTrue(clock.isDST(1772953200));
        assertTrue(clock.isDST(1793512799));
        assertFalse(clock.isDST(1793512800));
    }

    function test_isOpen_summer() public view {
        // 2026-10-07 (EDT): open 13:30 UTC, close 20:00 UTC
        assertFalse(clock.isOpen(1791379799));
        assertTrue(clock.isOpen(1791379800));
        assertTrue(clock.isOpen(1791403199));
        assertFalse(clock.isOpen(1791403200));
    }

    function test_isOpen_winter() public view {
        // 2026-01-07 (EST): open 14:30 UTC
        assertFalse(clock.isOpen(1767796199));
        assertTrue(clock.isOpen(1767796200));
    }

    function test_weekendClosed() public view {
        assertFalse(clock.isOpen(1791644400)); // Saturday 2026-10-10 11:00 ET
        assertFalse(clock.isTradingDay(20736));
    }

    function test_holidaysAndEarlyClose() public {
        uint256[] memory days_ = new uint256[](1);
        days_[0] = 20733;
        vm.prank(admin);
        clock.setHolidays(days_, true);
        assertFalse(clock.isOpen(1791379800 + 1 hours));
        vm.prank(admin);
        clock.setHolidays(days_, false);
        assertTrue(clock.isOpen(1791379800 + 1 hours));

        vm.prank(admin);
        clock.setEarlyClose(20733, 13 * 60);
        assertEq(clock.closeMinuteOf(20733), 13 * 60);
        assertFalse(clock.isOpen(1791403200 - 3 hours)); // 13:00 ET
        assertTrue(clock.isOpen(1791403200 - 3 hours - 1));
        assertEq(clock.closeTimestamp(20733), 1791403200 - 3 hours);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GoldbenchAccess.OutOfBounds.selector, 500, 571, 960));
        clock.setEarlyClose(20733, 500);
        vm.prank(admin);
        clock.setEarlyClose(20733, 0);
        assertEq(clock.closeMinuteOf(20733), 16 * 60);
    }

    function test_setHolidays_batchLimit() public {
        uint256[] memory days_ = new uint256[](33);
        vm.prank(admin);
        vm.expectRevert(MarketClock.BatchTooLarge.selector);
        clock.setHolidays(days_, true);
    }

    function test_guardianEmergencyCloseOnly() public {
        vm.prank(guardian);
        clock.emergencyClose(20733);
        assertTrue(clock.isHoliday(20733));
        uint256[] memory days_ = new uint256[](1);
        vm.prank(guardian);
        vm.expectRevert();
        clock.setHolidays(days_, false);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        clock.emergencyClose(20734);
    }

    function test_lastCompletedSession() public {
        // Wednesday after close → Wednesday
        assertEq(clock.lastCompletedSession(1791403200 + 1), 20733);
        // Wednesday during session → Tuesday
        assertEq(clock.lastCompletedSession(1791403200 - 1), 20732);
        // Saturday → Friday
        assertEq(clock.lastCompletedSession(1791644400), 20735);
        // Monday morning after a Friday holiday → Thursday
        uint256[] memory days_ = new uint256[](1);
        days_[0] = 20735;
        vm.prank(admin);
        clock.setHolidays(days_, true);
        assertEq(clock.lastCompletedSession(1791644400), 20734);
    }

    function test_lastCompletedSession_revertsIfNone() public {
        uint256[] memory days_ = new uint256[](20);
        for (uint256 i; i < 20; ++i) days_[i] = 20733 - i;
        vm.prank(admin);
        clock.setHolidays(days_, true);
        vm.expectRevert(MarketClock.NoRecentSession.selector);
        clock.lastCompletedSession(1791403200 + 1);
    }

    function test_pauseAccess() public {
        vm.prank(guardian);
        clock.pause();
        assertTrue(clock.paused());
        vm.prank(guardian);
        vm.expectRevert();
        clock.unpause();
        vm.prank(admin);
        clock.unpause();
        assertFalse(clock.paused());
    }

    function test_constructorZeroAdmin() public {
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        new MarketClock(address(0));
    }
}

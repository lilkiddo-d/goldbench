// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {PriceHistory} from "../../src/signal/PriceHistory.sol";
import {GoldbenchAccess} from "../../src/access/GoldbenchAccess.sol";
import {IOracleAdapter, IMarketClock} from "../../src/interfaces/IGoldbench.sol";

contract PriceHistoryTest is Fixture {
    function test_recordOncePerSession() public {
        _recordNextDay();
        assertEq(history.count(address(spy)), 1);
        assertEq(history.latestClose(address(spy)), 500e18);
        uint256 day = history.lastDay(address(spy));
        // second call same evening is a no-op
        vm.prank(keeper);
        history.recordDailyCloses();
        assertEq(history.count(address(spy)), 1);
        assertEq(history.lastDay(address(spy)), day);
        assertTrue(history.seedingClosed(address(spy)));
    }

    function test_recordWindowEnforced() public {
        _recordNextDay();
        uint256 day = clock.etDay(block.timestamp);
        uint256 next = _nextTradingDay(day);
        vm.warp(clock.closeTimestamp(next) + 9 hours);
        _pushPrices();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.OutsideRecordWindow.selector, next));
        history.recordDailyCloses();
    }

    function test_onlyKeeperRecords() public {
        vm.expectRevert();
        history.recordDailyCloses();
    }

    function test_pausedBlocksRecording() public {
        bytes32 role = history.GUARDIAN_ROLE();
        vm.prank(admin);
        history.grantRole(role, guardian);
        vm.prank(guardian);
        history.pause();
        vm.warp(clock.closeTimestamp(_nextTradingDay(clock.etDay(block.timestamp))) + 1);
        vm.prank(keeper);
        vm.expectRevert();
        history.recordDailyCloses();
    }

    function test_clampsOutlier() public {
        _recordNextDay();
        pSpy = 5000e8; // 10x fat-finger print
        _recordNextDay();
        assertEq(history.latestClose(address(spy)), 575e18); // +15 % clamp
        pSpy = 1e8;
        _recordNextDay();
        // clamp is relative to the last *stored* close
        assertEq(history.latestClose(address(spy)), (575e18 * 8500) / 10_000);
    }

    function test_skipsFailingOracleButRecordsOthers() public {
        spy.setOraclePaused(true);
        _recordNextDay();
        assertEq(history.count(address(spy)), 0);
        assertEq(history.count(address(qqq)), 1);
    }

    function test_ringBufferWraps() public {
        _buildHistory(300, 1, 0, 0);
        assertEq(history.count(address(spy)), 256);
        uint256[] memory r = history.recentCloses(address(spy), 300);
        assertEq(r.length, 256);
        assertEq(r[0], history.latestClose(address(spy)));
        assertEq(r[255], history.closeAt(address(spy), 255));
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.InsufficientHistory.selector, 256, 257));
        history.closeAt(address(spy), 256);
    }

    function test_smaMedianVol() public {
        vm.prank(admin);
        history.setMaxJumpBps(5000);
        int256[5] memory path = [int256(100e8), 110e8, 90e8, 120e8, 100e8];
        for (uint256 i; i < 5; ++i) {
            pSpy = path[i];
            _recordNextDay();
        }
        assertEq(history.sma(address(spy), 5), 104e18);
        assertEq(history.sma(address(spy), 1), 100e18);
        // last three: 90, 120, 100 → median 100
        assertEq(history.median3(address(spy)), 100e18);
        uint256 vol = history.volatility(address(spy), 4);
        assertGt(vol, 20_000); // very choppy path → > 200 % annualised
        vm.expectRevert(PriceHistory.ZeroWindow.selector);
        history.sma(address(spy), 0);
        vm.expectRevert(PriceHistory.ZeroWindow.selector);
        history.volatility(address(spy), 1);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.InsufficientHistory.selector, 5, 6));
        history.sma(address(spy), 6);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.InsufficientHistory.selector, 5, 6));
        history.volatility(address(spy), 5);
    }

    function test_medianEdgeCases() public {
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.InsufficientHistory.selector, 0, 1));
        history.median3(address(spy));
        _recordNextDay();
        assertEq(history.median3(address(spy)), 500e18);
        assertEq(history.latestClose(address(0xdead)), 0);
    }

    function test_constantPriceZeroVol() public {
        _buildHistory(25, 0, 0, 0);
        assertEq(history.volatility(address(spy), 20), 0);
    }

    function test_seedFromOracle() public {
        // three historical rounds on consecutive trading days before "now"
        uint256 d0 = clock.daysFromCivil(2025, 1, 6); // Monday
        vm.warp(clock.closeTimestamp(d0 + 3) + 1 hours);
        fSpy.setPriceAt(400e8, clock.closeTimestamp(d0)); // round 2
        fSpy.setPriceAt(410e8, clock.closeTimestamp(d0 + 1)); // round 3
        fSpy.setPriceAt(420e8, clock.closeTimestamp(d0 + 2)); // round 4
        uint80[] memory ids = new uint80[](3);
        ids[0] = 2;
        ids[1] = 3;
        ids[2] = 4;
        vm.prank(keeper);
        history.seedFromOracle(address(spy), ids);
        assertEq(history.count(address(spy)), 3);
        assertEq(history.latestClose(address(spy)), 420e18);
        assertEq(history.lastDay(address(spy)), d0 + 2);

        // replay / out-of-order rejected
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.NonIncreasingDay.selector, d0, d0 + 2));
        history.seedFromOracle(address(spy), ids);

        vm.prank(keeper);
        history.closeSeeding(address(spy));
        vm.prank(keeper);
        vm.expectRevert(PriceHistory.SeedingIsClosed.selector);
        history.seedFromOracle(address(spy), ids);
    }

    function test_seedSkipsMisScaledRounds() public {
        uint256 d0 = clock.daysFromCivil(2025, 1, 6); // Monday
        vm.warp(clock.closeTimestamp(d0 + 3) + 1 hours);
        fSpy.setPriceAt(742e16, clock.closeTimestamp(d0)); // round 2: ~1e8x too large (real launch-day pattern)
        fSpy.setPriceAt(495e8, clock.closeTimestamp(d0 + 1)); // round 3: sane
        fSpy.setPriceAt(1e8, clock.closeTimestamp(d0 + 2)); // round 4: 500x too small
        fSpy.setPrice(500e8); // live
        uint80[] memory ids = new uint80[](3);
        ids[0] = 2;
        ids[1] = 3;
        ids[2] = 4;
        vm.prank(keeper);
        history.seedFromOracle(address(spy), ids);
        assertEq(history.count(address(spy)), 1);
        assertEq(history.latestClose(address(spy)), 495e18);
    }

    function test_resetSeries() public {
        _recordNextDay();
        _recordNextDay();
        assertTrue(history.seedingClosed(address(spy)));
        vm.expectRevert();
        history.resetSeries(address(spy));
        vm.prank(admin);
        history.resetSeries(address(spy));
        assertEq(history.count(address(spy)), 0);
        assertFalse(history.seedingClosed(address(spy)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.NotTracked.selector, address(1)));
        history.resetSeries(address(1));
        _recordNextDay();
        assertEq(history.count(address(spy)), 1);
    }

    function test_seedRejectsWeekendAndFuture() public {
        uint256 sat = clock.daysFromCivil(2025, 1, 4);
        vm.warp(clock.closeTimestamp(sat + 3) + 1 hours);
        fGld.setPriceAt(250e8, sat * 1 days + 18 hours); // round 2 on a Saturday
        fGld.setPrice(250e8); // round 3: fresh live price (seeding needs a live reference)
        uint80[] memory ids = new uint80[](1);
        ids[0] = 2;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.NotATradingSession.selector, sat));
        history.seedFromOracle(address(gld), ids);

        // round 3 is stamped during Wednesday's still-open session → not a completed session yet
        vm.warp(clock.closeTimestamp(sat + 4) - 3 hours);
        fGld.setPrice(251e8);
        ids[0] = 4;
        vm.prank(keeper);
        vm.expectRevert();
        history.seedFromOracle(address(gld), ids);
    }

    function test_seedGuards() public {
        uint80[] memory ids = new uint80[](65);
        vm.startPrank(keeper);
        vm.expectRevert(PriceHistory.BatchTooLarge.selector);
        history.seedFromOracle(address(spy), ids);
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.NotTracked.selector, address(1)));
        history.seedFromOracle(address(1), new uint80[](0));
        vm.expectRevert(abi.encodeWithSelector(PriceHistory.NotTracked.selector, address(1)));
        history.closeSeeding(address(1));
        vm.stopPrank();
    }

    function test_adminSetters() public {
        vm.startPrank(admin);
        history.setMaxJumpBps(2000);
        assertEq(history.maxJumpBps(), 2000);
        vm.expectRevert(abi.encodeWithSelector(GoldbenchAccess.OutOfBounds.selector, 100, 500, 5000));
        history.setMaxJumpBps(100);
        history.setMaxRecordDelay(2 hours);
        assertEq(history.maxRecordDelay(), 2 hours);
        vm.expectRevert();
        history.setMaxRecordDelay(30 hours);
        history.setOracle(IOracleAdapter(address(oracle)));
        history.setClock(IMarketClock(address(clock)));
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        history.setOracle(IOracleAdapter(address(0)));
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        history.setClock(IMarketClock(address(0)));
        vm.expectRevert(PriceHistory.AlreadyTracked.selector);
        history.addAsset(address(spy));
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        history.addAsset(address(0));
        for (uint160 i = 1; i <= 4; ++i) history.addAsset(address(i));
        vm.expectRevert(PriceHistory.TooManyAssets.selector);
        history.addAsset(address(99));
        vm.stopPrank();
        assertEq(history.assets().length, 8);
    }

    function test_constructorZero() public {
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        new PriceHistory(admin, IOracleAdapter(address(0)), IMarketClock(address(clock)));
    }
}

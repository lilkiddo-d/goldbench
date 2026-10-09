// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {SignalEngine} from "../../src/signal/SignalEngine.sol";
import {Allocator} from "../../src/signal/Allocator.sol";
import {GoldbenchAccess} from "../../src/access/GoldbenchAccess.sol";
import {ISignalEngine, IPriceHistory} from "../../src/interfaces/IGoldbench.sol";

contract SignalEngineTest is Fixture {
    function test_insufficientHistory() public {
        _buildHistory(10, 10, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SignalEngine.InsufficientHistory.selector, 10, 50));
        engine.computeSignal();
    }

    function test_uptrendIsRiskOn() public {
        _buildHistory(210, 10, 0, 30);
        ISignalEngine.Signal memory s = engine.computeSignal();
        assertTrue(s.riskOn);
        assertTrue(s.strongTrend);
        assertGt(s.basketRatioLong, 1e18);
        assertGt(s.stockScaleBps, 0);
        assertEq(s.historyDays, 210);
    }

    function test_downtrendIsRiskOff() public {
        _buildHistory(210, -10, 5, 30);
        ISignalEngine.Signal memory s = engine.computeSignal();
        assertFalse(s.riskOn);
        assertEq(s.stockScaleBps, 0);
        assertEq(s.goldShareBps, 6000); // gold in uptrend → gold-heavy defensive sleeve
    }

    function test_goldDowntrendShiftsToTbills() public {
        _buildHistory(210, -10, -5, 0);
        ISignalEngine.Signal memory s = engine.computeSignal();
        assertEq(s.goldShareBps, 2000);
    }

    function test_volatilityScalesDown() public {
        _buildHistory(210, 10, 0, 0);
        ISignalEngine.Signal memory calm = engine.computeSignal();
        _buildHistory(25, 10, 0, 400); // violent last month
        ISignalEngine.Signal memory wild = engine.computeSignal();
        assertTrue(wild.riskOn);
        assertGt(wild.basketVolBps, calm.basketVolBps);
        assertLt(wild.stockScaleBps, calm.stockScaleBps);
        assertGe(wild.stockScaleBps, 2500); // floored at minVolScale
    }

    function test_weakTrendHalfScale() public {
        // V-shape: long decline, base, sharp rebound → spot > 200d MA but 50d MA < 200d MA
        _buildHistory(150, -20, 0, 0);
        _buildHistory(40, 0, 0, 0);
        _buildHistory(10, 150, 0, 0);
        ISignalEngine.Signal memory s = engine.computeSignal();
        assertTrue(s.riskOn);
        assertFalse(s.strongTrend);
        assertEq(s.stockScaleBps, 5000);
    }

    function test_hysteresisHoldsPreviousRegime() public {
        _buildHistory(210, 10, 0, 0);
        vm.prank(address(steady));
        engine.refreshSignal();
        assertTrue(engine.riskOnState());
        // move basket to just under its MA but inside the 1 % band
        vm.prank(admin);
        engine.setParam(5, 500); // 5 % band
        int256 ratioTarget = 10_000 - 100; // −1 %
        pSpy = (int256(history.sma(address(spy), 200) / 1e10) * ratioTarget) / 10_000;
        pQqq = (int256(history.sma(address(qqq), 200) / 1e10) * ratioTarget) / 10_000;
        for (uint256 i; i < 3; ++i) _recordNextDay();
        ISignalEngine.Signal memory s = engine.computeSignal();
        assertLt(s.basketRatioLong, 1e18);
        assertTrue(s.riskOn, "inside band keeps risk-on");
    }

    function test_goldWarmupIsNeutral() public {
        // gold feed goes dark for the whole build → gold series stays empty, basket still produces a signal
        gld.setOraclePaused(true);
        _buildHistory(60, 10, 0, 0);
        ISignalEngine.Signal memory s = engine.computeSignal();
        assertEq(history.count(address(gld)), 0);
        assertTrue(s.riskOn);
        assertEq(s.goldRatioLong, 0);
        assertEq(s.goldVolBps, 0);
        assertEq(s.goldShareBps, 4000); // midpoint of 6000/2000
    }

    function test_refreshOnlyVault() public {
        _buildHistory(60, 10, 0, 0);
        vm.expectRevert();
        engine.refreshSignal();
        vm.prank(address(bold));
        ISignalEngine.Signal memory s = engine.refreshSignal();
        assertEq(engine.riskOnState(), s.riskOn);
    }

    function test_paramBoundsAndConsistency() public {
        vm.startPrank(admin);
        engine.setParam(0, 150);
        assertEq(engine.param(0), 150);
        vm.expectRevert(abi.encodeWithSelector(GoldbenchAccess.OutOfBounds.selector, 300, 100, 250));
        engine.setParam(0, 300);
        vm.expectRevert(SignalEngine.InconsistentParams.selector);
        engine.setParam(1, 100); // minHistory(50) < maShort(100)
        vm.expectRevert(SignalEngine.InconsistentParams.selector);
        engine.setParam(9, 15 + 15); // minHistory 30 < maShort 50
        vm.expectRevert(abi.encodeWithSelector(SignalEngine.UnknownParam.selector, 10));
        engine.setParam(10, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(SignalEngine.UnknownParam.selector, 10));
        engine.param(10);
        for (uint8 i; i < 10; ++i) engine.bounds(i);
        assertEq(engine.params()[3], 1500);
        vm.expectRevert();
        engine.setParam(3, 1000); // not admin
    }

    function testFuzz_validateParamNeverAcceptsOutOfBounds(uint8 id, uint256 v) public view {
        id = uint8(bound(id, 0, 9));
        (uint256 min, uint256 max) = engine.bounds(id);
        if (v < min || v > max) {
            try engine.validateParam(id, v) {
                revert("accepted out-of-bounds");
            } catch {}
        }
    }

    function test_basketValidation() public {
        address[] memory a = new address[](2);
        uint16[] memory w = new uint16[](2);
        a[0] = address(spy);
        a[1] = address(spy);
        w[0] = 5000;
        w[1] = 5000;
        vm.startPrank(admin);
        vm.expectRevert(SignalEngine.InvalidBasket.selector);
        engine.setBasket(a, w); // duplicate
        a[1] = address(qqq);
        w[1] = 4000;
        vm.expectRevert(SignalEngine.InvalidBasket.selector);
        engine.setBasket(a, w); // sum != 10000
        vm.expectRevert(SignalEngine.InvalidBasket.selector);
        engine.setBasket(new address[](0), new uint16[](0));
        w[1] = 0;
        vm.expectRevert(SignalEngine.InvalidBasket.selector);
        engine.setBasket(a, w);
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        engine.setDefensiveAssets(address(gld), address(gld));
        engine.setHistory(IPriceHistory(address(history)));
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        engine.setHistory(IPriceHistory(address(0)));
        vm.stopPrank();
        (address[] memory ba, uint16[] memory bw) = engine.basket();
        assertEq(ba.length, 2);
        assertEq(bw[0], 6000);
    }

    function test_computeRevertsWithoutBasket() public {
        vm.prank(admin);
        SignalEngine e = new SignalEngine(admin, IPriceHistory(address(history)));
        vm.expectRevert(SignalEngine.InvalidBasket.selector);
        e.computeSignal();
        vm.expectRevert(GoldbenchAccess.ZeroAddress.selector);
        new SignalEngine(admin, IPriceHistory(address(0)));
    }

    // ───────────────────────── outlier robustness (spec requirement) ─────────────────────────

    /// forge-config: default.fuzz.runs = 24
    /// @notice A single outlier print — of any size, in either direction, on the latest day — never flips the regime.
    function testFuzz_singleOutlierCannotFlipRegime(uint256 mult, bool up, bool startRiskOn) public {
        _buildHistory(210, startRiskOn ? int256(8) : int256(-8), 0, 20);
        vm.prank(address(bold));
        ISignalEngine.Signal memory before = engine.refreshSignal();
        assertEq(before.riskOn, startRiskOn);

        mult = bound(mult, 2, 1000);
        int256 save = pSpy;
        int256 saveQ = pQqq;
        pSpy = up ? pSpy * int256(mult) : pSpy / int256(mult);
        pQqq = up ? pQqq * int256(mult) : pQqq / int256(mult);
        if (pSpy == 0) pSpy = 1;
        if (pQqq == 0) pQqq = 1;
        _recordNextDay();
        ISignalEngine.Signal memory afterOutlier = engine.computeSignal();
        assertEq(afterOutlier.riskOn, before.riskOn, "single outlier flipped the regime");

        // prices revert to normal next day → still the same regime
        pSpy = save;
        pQqq = saveQ;
        _recordNextDay();
        assertEq(engine.computeSignal().riskOn, before.riskOn);
    }
}

contract AllocatorTest is Fixture {
    function _sig(bool on, uint256 scale, uint256 goldShare) internal view returns (ISignalEngine.Signal memory s) {
        s.riskOn = on;
        s.stockScaleBps = scale;
        s.goldShareBps = goldShare;
        s.timestamp = block.timestamp;
    }

    function test_riskOnFullScale() public view {
        (address[] memory a, uint16[] memory w) = allocator.computeTargets(_sig(true, 10_000, 6000), 7000, 300);
        assertEq(a.length, 4);
        assertEq(a[0], address(spy));
        assertEq(uint256(w[0]) + w[1], 7000);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3] + 300, 10_000);
    }

    function test_riskOffNoStocks() public view {
        (, uint16[] memory w) = allocator.computeTargets(_sig(false, 10_000, 6000), 10_000, 300);
        assertEq(w[0], 0);
        assertEq(w[1], 0);
        assertEq(w[2], (9700 * 6000) / 10_000);
    }

    function test_boldCapLimitedByBuffer() public view {
        (, uint16[] memory w) = allocator.computeTargets(_sig(true, 10_000, 6000), 10_000, 300);
        assertEq(uint256(w[0]) + w[1], 9700);
    }

    function test_invalidCap() public {
        vm.expectRevert(Allocator.InvalidCap.selector);
        allocator.computeTargets(_sig(true, 1, 1), 10_001, 0);
    }

    /// @notice Spec invariant: allocations never exceed each vault's stock cap and always sum to 100 %.
    function testFuzz_neverExceedsCap(bool on, uint256 scale, uint256 goldShare, uint16 cap, uint16 buffer) public view {
        cap = uint16(bound(cap, 0, 10_000));
        buffer = uint16(bound(buffer, 0, 2000));
        (, uint16[] memory w) = allocator.computeTargets(_sig(on, scale, goldShare), cap, buffer);
        uint256 stocks = uint256(w[0]) + w[1];
        assertLe(stocks, cap);
        assertEq(stocks + w[2] + w[3] + buffer, 10_000);
    }
}

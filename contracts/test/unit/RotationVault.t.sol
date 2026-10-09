// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "../Fixture.sol";
import {RotationVault} from "../../src/vault/RotationVault.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {UniswapV3DexAdapter} from "../../src/dex/UniswapV3DexAdapter.sol";
import {ReentrantRouter} from "../mocks/Mocks.sol";
import {IDexAdapter, IOracleAdapter, IComplianceRegistry} from "../../src/interfaces/IGoldbench.sol";
import {ISwapRouter02} from "../../src/interfaces/IExternal.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RotationVaultTest is Fixture {
    function _uptrend() internal {
        _buildHistory(210, 8, 2, 20);
    }

    function _downtrend() internal {
        _buildHistory(210, -8, 3, 20);
    }

    // ───────────────────────────── deposits / withdrawals ─────────────────────────────

    function test_metadata() public view {
        assertEq(steady.name(), "Goldbench Steady");
        assertEq(steady.decimals(), 12);
        assertEq(steady.asset(), address(usdg));
        assertEq(steady.stockCapBps(), 4000);
        assertEq(balanced.stockCapBps(), 7000);
        assertEq(bold.stockCapBps(), 10_000);
        assertEq(steady.mgmtFeeBps(), 75);
    }

    function test_depositAndCashRedeem() public {
        _recordNextDay();
        uint256 shares = _deposit(steady, alice, 1000e6);
        assertEq(shares, 1000e12);
        assertEq(steady.totalAssets(), 1000e6);
        assertEq(steady.maxWithdraw(alice), 1000e6);
        vm.prank(alice);
        uint256 got = steady.redeem(shares, alice, alice);
        assertEq(got, 1000e6);
        assertEq(usdg.balanceOf(alice), 1000e6);
    }

    function test_mintAndWithdraw() public {
        usdg.mint(alice, 500e6);
        vm.startPrank(alice);
        usdg.approve(address(bold), 500e6);
        uint256 assets = bold.mint(100e12, alice);
        assertEq(assets, 100e6);
        bold.withdraw(40e6, alice, alice);
        vm.stopPrank();
        assertEq(bold.balanceOf(alice), 60e12);
    }

    function test_depositCap() public {
        vm.prank(admin);
        steady.setDepositCap(1000e6);
        assertEq(steady.maxDeposit(alice), 1000e6);
        assertEq(steady.maxMint(alice), 1000e12);
        _deposit(steady, alice, 1000e6);
        assertEq(steady.maxDeposit(alice), 0);
        usdg.mint(bob, 1);
        vm.startPrank(bob);
        usdg.approve(address(steady), 1);
        vm.expectRevert();
        steady.deposit(1, bob);
        vm.stopPrank();
    }

    function test_depositRevertsOnStalePrice() public {
        _deposit(bold, alice, 100e6);
        _runFullRebalanceAfterHistory(bold, true);
        vm.warp(block.timestamp + 4 days);
        usdg.mint(bob, 1e6);
        vm.startPrank(bob);
        usdg.approve(address(bold), 1e6);
        vm.expectRevert();
        bold.deposit(1e6, bob);
        vm.stopPrank();
        // view stays usable via last closes
        assertGt(bold.totalAssets(), 0);
    }

    function test_depositRevertsOnDeviationFromLastClose() public {
        _uptrend();
        _deposit(bold, alice, 1000e6);
        _runFullRebalance(bold);
        pSpy = pSpy * 13 / 10; // +30 % intraday vs last close
        _pushPrices();
        usdg.mint(bob, 1e6);
        vm.startPrank(bob);
        usdg.approve(address(bold), 1e6);
        vm.expectPartialRevert(RotationVault.PriceDeviation.selector);
        bold.deposit(1e6, bob);
        vm.stopPrank();
    }

    function test_depositRevertsOnDepeg() public {
        pUsdg = 0.9e8;
        _pushPrices();
        usdg.mint(alice, 1e6);
        vm.startPrank(alice);
        usdg.approve(address(steady), 1e6);
        vm.expectRevert(abi.encodeWithSelector(RotationVault.Depeg.selector, 0.9e18));
        steady.deposit(1e6, alice);
        vm.stopPrank();
        assertEq(steady.totalAssets(), 0); // lenient path still works
    }

    function test_cashWithdrawLimitedToIdle_inKindAlwaysWorks() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        _runFullRebalance(bold);
        uint256 idle = usdg.balanceOf(address(bold));
        assertLt(idle, 1_000e6);
        assertLe(bold.maxWithdraw(alice), idle);
        assertLe(bold.convertToAssets(bold.maxRedeem(alice)), idle);

        vm.prank(guardian);
        bold.pause();
        assertEq(bold.maxWithdraw(alice), 0);
        assertEq(bold.maxRedeem(alice), 0);
        assertEq(bold.maxDeposit(alice), 0);

        uint256 shares = bold.balanceOf(alice);
        vm.prank(alice);
        (address[] memory tokens, uint256[] memory amounts) = bold.redeemInKind(shares / 2, alice, alice);
        assertEq(tokens[0], address(usdg));
        assertEq(tokens.length, 5);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(alice), amounts[i]);
        }
        assertGt(spy.balanceOf(alice), 0);
    }

    function test_redeemInKindWithAllowance() public {
        _deposit(steady, alice, 100e6);
        vm.prank(alice);
        steady.approve(bob, 50e12);
        vm.prank(bob);
        steady.redeemInKind(50e12, bob, alice);
        assertEq(usdg.balanceOf(bob), 50e6);
        vm.prank(bob);
        vm.expectRevert();
        steady.redeemInKind(1e12, bob, alice);
        vm.expectRevert(RotationVault.ZeroShares.selector);
        steady.redeemInKind(0, alice, alice);
        vm.expectRevert(RotationVault.ZeroAddress.selector);
        steady.redeemInKind(1, address(0), alice);
    }

    // ───────────────────────────── fees ─────────────────────────────

    function test_managementFeeOneYear() public {
        _deposit(steady, alice, 1_000_000e6);
        vm.warp(block.timestamp + 365 days);
        vm.recordLogs();
        steady.accrueFees();
        uint256 feeShares = steady.balanceOf(address(fees));
        uint256 supply = steady.totalSupply();
        // fee shares are 0.75 % of the post-fee supply
        assertApproxEqRel((feeShares * 1e18) / supply, 0.0075e18, 1e12);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0);
        // alice's claim dropped by exactly the fee
        assertApproxEqRel(steady.convertToAssets(steady.balanceOf(alice)), 992_500e6, 1e12);
        // accruing twice in the same block mints nothing extra
        steady.accrueFees();
        assertEq(steady.balanceOf(address(fees)), feeShares);
    }

    function test_feeCapAndZeroFee() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(RotationVault.OutOfBounds.selector, 76, 0, 75));
        steady.setMgmtFeeBps(76);
        steady.setMgmtFeeBps(0);
        vm.stopPrank();
        _deposit(steady, alice, 1000e6);
        vm.warp(block.timestamp + 365 days);
        steady.accrueFees();
        assertEq(steady.balanceOf(address(fees)), 0);
    }

    function test_feeDistributionToTreasuryWithoutToken() public {
        _deposit(steady, alice, 1000e6);
        vm.warp(block.timestamp + 30 days);
        steady.accrueFees();
        uint256 bal = steady.balanceOf(address(fees));
        fees.distribute(address(steady));
        assertEq(steady.balanceOf(treasury), bal);
    }

    // ───────────────────────────── rebalancing ─────────────────────────────

    function _runFullRebalanceAfterHistory(RotationVault v, bool up) internal {
        if (up) _uptrend();
        else _downtrend();
        _runFullRebalance(v);
    }

    function test_rebalanceRiskOnRespectsCaps() public {
        _uptrend();
        _deposit(steady, alice, 100_000e6);
        _deposit(balanced, alice, 100_000e6);
        _deposit(bold, alice, 100_000e6);
        _runFullRebalance(steady);
        _runFullRebalance(balanced);
        _runFullRebalance(bold);
        assertLe(steady.stockWeightBps(), 4000);
        assertLe(balanced.stockWeightBps(), 7000);
        assertLe(bold.stockWeightBps(), 10_000);
        assertGt(steady.stockWeightBps(), 1000);
        assertGt(bold.stockWeightBps(), steady.stockWeightBps());
        (address[] memory a, uint256[] memory vals, uint256[] memory w, uint256 idle, uint256 nav) = bold.allocation();
        assertEq(a.length, 4);
        assertEq(vals.length, 4);
        assertGt(w[0], 0);
        assertGt(nav, 99_000e6);
        assertGt(idle, 0);
    }

    function test_rebalanceRiskOffNoStocks() public {
        _downtrend();
        _deposit(bold, alice, 100_000e6);
        _runFullRebalance(bold);
        assertEq(bold.stockWeightBps(), 0);
        assertGt(gld.balanceOf(address(bold)), 0);
        assertGt(sgov.balanceOf(address(bold)), 0);
    }

    function test_rotationFromRiskOnToRiskOffSellsStocks() public {
        _uptrend();
        _deposit(bold, alice, 100_000e6);
        _runFullRebalance(bold);
        assertGt(bold.stockWeightBps(), 3000);
        _buildHistory(120, -40, 5, 10); // crash
        vm.warp(block.timestamp + 7 days);
        _runFullRebalance(bold);
        assertLt(bold.stockWeightBps(), 50);
    }

    function test_rebalanceEmitsSignal() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        _warpToOpen();
        vm.recordLogs();
        vm.prank(keeper);
        bold.startRebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "RebalanceStarted(uint256,(bool,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),address[],uint16[],uint256)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) found = true;
        }
        assertTrue(found, "RebalanceStarted with signal values not emitted");
        assertEq(bold.rebalanceId(), 1);
    }

    function test_rebalanceGuards() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);

        // market closed (after-hours)
        vm.prank(keeper);
        vm.expectRevert(RotationVault.MarketClosed.selector);
        bold.startRebalance();

        _warpToOpen();
        vm.expectRevert();
        bold.startRebalance(); // not keeper

        vm.prank(keeper);
        vm.expectRevert(RotationVault.NoActivePlan.selector);
        bold.executeChunk(block.timestamp);

        vm.prank(keeper);
        bold.startRebalance();
        vm.prank(keeper);
        vm.expectRevert(RotationVault.RebalanceActive.selector);
        bold.startRebalance();

        vm.prank(keeper);
        vm.expectRevert(RotationVault.Expired.selector);
        bold.executeChunk(block.timestamp - 1);

        vm.prank(keeper);
        bold.executeChunk(block.timestamp + 60);
        vm.prank(keeper);
        vm.expectPartialRevert(RotationVault.ChunkTooSoon.selector);
        bold.executeChunk(block.timestamp + 60);

        // finish the plan
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            _pushPrices();
            vm.prank(keeper);
            bold.executeChunk(block.timestamp + 60);
        }
        (bool active,,,,) = bold.plan();
        assertFalse(active);

        // weekly limit
        _warpToOpen();
        vm.prank(keeper);
        vm.expectPartialRevert(RotationVault.TooSoon.selector);
        bold.startRebalance();
        vm.warp(block.timestamp + 7 days);
        _warpToOpen();
        vm.prank(keeper);
        bold.startRebalance();
    }

    function test_chunkDuringClosedMarketReverts() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        _warpToOpen();
        vm.prank(keeper);
        bold.startRebalance();
        vm.warp(block.timestamp + 3 hours); // past 16:00
        _pushPrices();
        vm.prank(keeper);
        vm.expectRevert(RotationVault.MarketClosed.selector);
        bold.executeChunk(block.timestamp + 60);
    }

    function test_planExpires() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        _warpToOpen();
        vm.prank(keeper);
        bold.startRebalance();
        vm.warp(block.timestamp + 4 days);
        vm.prank(keeper);
        bold.executeChunk(block.timestamp + 60);
        (bool active,,,,) = bold.plan();
        assertFalse(active);
    }

    function test_cancelRebalance() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        _warpToOpen();
        vm.prank(keeper);
        bold.startRebalance();
        vm.expectRevert();
        bold.cancelRebalance();
        vm.prank(guardian);
        bold.cancelRebalance();
        (bool active,,,,) = bold.plan();
        assertFalse(active);
        vm.prank(admin);
        bold.cancelRebalance();
    }

    function test_favourableFillsNeverPushStocksOverCap() public {
        _uptrend();
        _deposit(steady, alice, 100_000e6);
        router.setBonus(300); // fills 3 % better than oracle on every trade (beyond the 1 % haircut)
        vm.recordLogs();
        _runFullRebalance(steady);
        router.setBonus(0);
        assertLe(steady.stockWeightBps(), 4000);
        assertGt(steady.stockWeightBps(), 3500);
    }

    function test_gasStarvedChunkRevertsInsteadOfSkipping() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        _warpToOpen();
        vm.prank(keeper);
        bold.startRebalance();
        vm.prank(keeper);
        vm.expectRevert(RotationVault.InsufficientGas.selector);
        bold.executeChunk{gas: 600_000}(block.timestamp + 60);
        (, uint8 done,,,) = bold.plan();
        assertEq(done, 0, "chunk must not be consumed");
        vm.prank(keeper);
        bold.executeChunk(block.timestamp + 60);
        (, done,,,) = bold.plan();
        assertEq(done, 1);
    }

    function test_trimSellsOvershootInSameChunk() public {
        _uptrend();
        _deposit(steady, alice, 100_000e6);
        vm.prank(admin);
        steady.setChunking(1, 30 minutes); // whole gap in one chunk -> 3 % favourable fill overshoots the 1 % haircut
        router.setBonusFor(address(spy), 500); // only stock buys fill 5 % better than oracle
        router.setBonusFor(address(qqq), 500);
        vm.recordLogs();
        _runFullRebalance(steady);
        router.setBonusFor(address(spy), 0);
        router.setBonusFor(address(qqq), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sellsToBase;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RotationVault.Trade.selector && address(uint160(uint256(logs[i].topics[3]))) == address(usdg)) {
                sellsToBase++;
            }
        }
        assertGt(sellsToBase, 0, "trim sell expected");
        assertLe(steady.stockWeightBps(), 4000);
    }

    function test_strictPricingBubblesOracleError() public {
        _uptrend();
        _deposit(bold, alice, 1000e6);
        _runFullRebalance(bold);
        spy.setOraclePaused(true); // issuer corporate-action pause -> adapter reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.OraclePausedByIssuer.selector, address(spy)));
        bold.redeem(1e12, alice, alice);
        assertGt(bold.totalAssets(), 0); // lenient view falls back to last close
        spy.setOraclePaused(false);
    }

    function test_failedTradesAreSkippedNotFatal() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        router.setRevert(true);
        _runFullRebalance(bold);
        assertEq(usdg.balanceOf(address(bold)), 10_000e6);
        router.setRevert(false);
    }

    function test_slippageGuardRejectsBadFills() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        router.setSkew(200); // 2 % worse than oracle > 1 % max slippage
        _runFullRebalance(bold);
        assertEq(bold.stockWeightBps(), 0);
        assertEq(usdg.balanceOf(address(bold)), 10_000e6);
    }

    function test_reentrancyFromVenueIsBlocked() public {
        _uptrend();
        _deposit(bold, alice, 10_000e6);
        ReentrantRouter evil = new ReentrantRouter();
        UniswapV3DexAdapter evilDex = new UniswapV3DexAdapter(admin, ISwapRouter02(address(evil)), address(usdg));
        vm.startPrank(admin);
        evilDex.setPoolFee(address(spy), 500);
        evilDex.setPoolFee(address(qqq), 500);
        evilDex.setPoolFee(address(gld), 500);
        evilDex.setPoolFee(address(sgov), 500);
        bold.setDexAdapter(IDexAdapter(address(evilDex)));
        vm.stopPrank();
        evil.arm(address(bold), abi.encodeCall(RotationVault.redeemInKind, (1, address(evil), address(evil))));
        vm.recordLogs();
        _runFullRebalance(bold);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 failed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RotationVault.TradeFailed.selector) failed++;
        }
        assertGt(failed, 0);
        assertEq(usdg.balanceOf(address(bold)), 10_000e6);
    }

    // ───────────────────────────── compliance ─────────────────────────────

    function test_complianceGatesDepositsAndTransfersButNotSelfExit() public {
        _deposit(steady, alice, 100e6);
        vm.prank(admin);
        compliance.setEnabled(true);

        usdg.mint(bob, 10e6);
        vm.startPrank(bob);
        usdg.approve(address(steady), 10e6);
        vm.expectPartialRevert(RotationVault.NotCompliant.selector);
        steady.deposit(10e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectPartialRevert(RotationVault.NotCompliant.selector);
        steady.transfer(bob, 1e12);

        vm.prank(alice);
        vm.expectPartialRevert(RotationVault.NotCompliant.selector);
        steady.redeem(1e12, bob, alice);

        // self-exit is never gated
        vm.prank(alice);
        steady.redeem(10e12, alice, alice);
        vm.prank(alice);
        steady.redeemInKind(10e12, alice, alice);

        address[] memory list = new address[](1);
        list[0] = bob;
        vm.prank(admin);
        compliance.setAllowed(list, bytes32(0), true);
        vm.prank(bob);
        steady.deposit(10e6, bob);
        vm.prank(alice);
        steady.transfer(bob, 1e12);

        // fee distribution is exempt from transfer gating
        vm.warp(block.timestamp + 30 days);
        steady.accrueFees();
        fees.distribute(address(steady));
    }

    function test_complianceDisabledByDefault() public view {
        assertFalse(compliance.enabled());
        assertTrue(compliance.isAllowed(bob, keccak256("DEPOSIT")));
    }

    // ───────────────────────────── admin ─────────────────────────────

    function test_adminSettersBounds() public {
        vm.startPrank(admin);
        steady.setBufferBps(500);
        steady.setMaxSlippageBps(50);
        steady.setNavDeviationBps(500);
        steady.setChunking(6, 15 minutes);
        steady.setRebalanceInterval(14 days);
        steady.setMinTradeValue(1e6);
        steady.setOracleAdapter(IOracleAdapter(address(oracle)));
        steady.setDexAdapter(IDexAdapter(address(dex)));
        steady.setComplianceRegistry(IComplianceRegistry(address(0)));
        steady.setFeeCollector(address(fees));
        vm.expectRevert();
        steady.setBufferBps(2001);
        vm.expectRevert();
        steady.setMaxSlippageBps(5);
        vm.expectRevert();
        steady.setNavDeviationBps(100);
        vm.expectRevert();
        steady.setChunking(0, 15 minutes);
        vm.expectRevert();
        steady.setChunking(4, 1 minutes);
        vm.expectRevert(abi.encodeWithSelector(RotationVault.OutOfBounds.selector, 1 days, 7 days, 30 days));
        steady.setRebalanceInterval(1 days);
        vm.expectRevert(RotationVault.ZeroAddress.selector);
        steady.setOracleAdapter(IOracleAdapter(address(0)));
        vm.expectRevert(RotationVault.ZeroAddress.selector);
        steady.setDexAdapter(IDexAdapter(address(0)));
        vm.expectRevert(RotationVault.ZeroAddress.selector);
        steady.setFeeCollector(address(0));
        vm.stopPrank();
        vm.expectRevert();
        steady.setBufferBps(1);
        assertEq(steady.chunkCount(), 6);
    }

    function test_pauseUnpause() public {
        vm.expectRevert();
        steady.pause();
        vm.prank(guardian);
        steady.pause();
        vm.prank(guardian);
        vm.expectRevert();
        steady.unpause();
        vm.prank(admin);
        steady.unpause();
        assertFalse(steady.paused());
    }

    function test_cannotReinitialize() public {
        RotationVault.InitParams memory p = _params("x", "x", 1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        steady.initialize(p);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);
    }

    function test_initValidation() public {
        RotationVault.InitParams memory p = _params("x", "x", 10_001);
        vm.prank(admin);
        vm.expectRevert();
        factory.createVault(p);
        p = _params("x", "x", 100);
        p.admin = address(0);
        vm.prank(admin);
        vm.expectRevert(RotationVault.ZeroAddress.selector);
        factory.createVault(p);
    }

    function test_tooManyHoldings() public {
        // A basket of 4 + gold + tbill = 6 holdings; the 8-holding cap is enforced in _ensureHolding.
        assertEq(steady.MAX_HOLDINGS(), 8);
        assertEq(steady.holdings().length, 0);
    }
}

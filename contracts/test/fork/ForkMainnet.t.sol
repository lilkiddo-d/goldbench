// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {SeedHistory} from "../../script/SeedHistory.s.sol";
import {RobinhoodMainnet as RH} from "../../script/Addresses.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {RotationVault} from "../../src/vault/RotationVault.sol";
import {ISignalEngine} from "../../src/interfaces/IGoldbench.sol";
import {IStockToken} from "../../src/interfaces/IExternal.sol";

/// @notice Fork tests against Robinhood Chain mainnet with the real token, oracle and Uniswap addresses.
///         The public RPC is not an archive node, so we fork the LATEST block (override with ROBINHOOD_RPC_URL and,
///         on an archive RPC, FORK_BLOCK). If the fork lands outside US market hours, tests warp to the next session
///         and simulate the feeds' next heartbeat (same answer, fresh timestamp) — prices are never altered.
contract ForkMainnetTest is Test {
    // Uniswap v3 USDG pools holding USDG (used only as a funding source via prank in tests)
    address internal constant USDG_WHALE_POOL = 0xD60A5d14dB690B7Afad71F76B108071D7175597d; // QQQ/USDG 0.05 %

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        assertEq(block.chainid, 4663);
    }

    function test_fork_realTokensAndFeeds() public {
        assertEq(IERC20Metadata(RH.USDG).decimals(), 6);
        assertEq(IERC20Metadata(RH.SPY).decimals(), 18);
        assertEq(IERC20Metadata(RH.QQQ).decimals(), 18);
        assertEq(IERC20Metadata(RH.GLD).decimals(), 18);
        assertEq(IERC20Metadata(RH.SGOV).decimals(), 18);
        assertEq(keccak256(bytes(IERC20Metadata(RH.SPY).symbol())), keccak256("SPY"));

        ChainlinkOracleAdapter o = new ChainlinkOracleAdapter(address(this));
        o.setFeed(RH.USDG, RH.USDG_USD_FEED, 30 hours, false);
        o.setFeed(RH.SPY, RH.SPY_USD_FEED, 30 hours, true);
        o.setFeed(RH.QQQ, RH.QQQ_USD_FEED, 30 hours, true);
        o.setFeed(RH.GLD, RH.GLD_USD_FEED, 30 hours, true);
        o.setFeed(RH.SGOV, RH.SGOV_USD_FEED, 30 hours, true);

        (uint256 usdg,) = o.getPrice(RH.USDG);
        (uint256 spy,) = o.getPrice(RH.SPY);
        (uint256 qqq,) = o.getPrice(RH.QQQ);
        (uint256 gld,) = o.getPrice(RH.GLD);
        (uint256 sgov,) = o.getPrice(RH.SGOV);
        console2.log("USDG", usdg / 1e14, "e-4 USD");
        console2.log("SPY ", spy / 1e18, "USD");
        console2.log("QQQ ", qqq / 1e18, "USD");
        console2.log("GLD ", gld / 1e18, "USD");
        console2.log("SGOV", sgov / 1e18, "USD");
        assertApproxEqRel(usdg, 1e18, 0.01e18);
        assertGt(spy, 300e18);
        assertLt(spy, 2000e18);
        assertGt(qqq, 300e18);
        assertGt(gld, 100e18);
        assertApproxEqRel(sgov, 100.5e18, 0.03e18);

        // issuer extensions documented by Robinhood exist on the real tokens
        assertFalse(IStockToken(RH.SPY).oraclePaused());
        assertGe(IStockToken(RH.SPY).uiMultiplier(), 1e18);
    }

    function _deploy() internal returns (Deploy.Deployed memory d) {
        vm.setEnv("GOLDBENCH_KEEPER", vm.toString(keeper));
        vm.setEnv("GOLDBENCH_WRITE_OUTPUTS", "false");
        Deploy script = new Deploy();
        d = script.run();
    }

    function _seed(Deploy.Deployed memory d) internal {
        SeedHistory s = new SeedHistory();
        address[] memory assets = d.history.assets();
        for (uint256 i; i < assets.length; ++i) {
            uint80[] memory ids = s.selectRounds(d.history, assets[i]);
            uint256 batch = d.history.MAX_SEED_BATCH();
            for (uint256 start; start < ids.length; start += batch) {
                uint256 end = start + batch > ids.length ? ids.length : start + batch;
                uint80[] memory c = new uint80[](end - start);
                for (uint256 j = start; j < end; ++j) c[j - start] = ids[j];
                vm.prank(keeper);
                d.history.seedFromOracle(assets[i], c);
            }
            console2.log("seeded sessions", assets[i], d.history.count(assets[i]));
        }
    }

    function _fund(address to, uint256 amount) internal {
        vm.prank(USDG_WHALE_POOL);
        IERC20(RH.USDG).transfer(to, amount);
    }

    address[5] internal FEEDS =
        [RH.USDG_USD_FEED, RH.SPY_USD_FEED, RH.QQQ_USD_FEED, RH.GLD_USD_FEED, RH.SGOV_USD_FEED];

    /// @dev Re-publish each feed's current answer with a fresh timestamp (simulates the next heartbeat).
    function _heartbeat() internal {
        for (uint256 i; i < FEEDS.length; ++i) {
            (bool ok, bytes memory ret) = FEEDS[i].staticcall(abi.encodeWithSignature("latestRoundData()"));
            require(ok, "feed");
            (uint80 id, int256 ans,,, uint80 air) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
            vm.mockCall(
                FEEDS[i],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(id, ans, block.timestamp, block.timestamp, air)
            );
        }
    }

    /// @dev Ensure we are inside a regular US session (11:00 New York) with fresh oracle timestamps.
    function _toSession(Deploy.Deployed memory d) internal {
        if (d.clock.isOpen(block.timestamp) && d.clock.isOpen(block.timestamp + 2 hours + 30 minutes)) return;
        uint256 day = d.clock.etDay(block.timestamp);
        if (d.clock.isTradingDay(day) && block.timestamp < d.clock.closeTimestamp(day) - 5 hours) {
            // before today's open
        } else {
            day++;
        }
        while (!d.clock.isTradingDay(day)) day++;
        vm.warp(d.clock.closeTimestamp(day) - 5 hours); // 11:00 New York
        _heartbeat();
    }

    function test_fork_deployScriptWiresAndHandsOff() public {
        Deploy.Deployed memory d = _deploy();
        assertEq(d.factory.vaultCount(), 3);
        assertEq(RotationVault(d.bold).stockCapBps(), 10_000);
        assertEq(RotationVault(d.steady).stockCapBps(), 4000);
        assertTrue(d.history.hasRole(d.history.KEEPER_ROLE(), keeper));
        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), address(d.hooks)));
        assertEq(d.hooks.projectToken(), address(0));
        _toSession(d);
        assertTrue(d.clock.isOpen(block.timestamp));
        assertTrue(d.clock.isHoliday(20783)); // Thanksgiving 2026
    }

    function test_fork_seedSignalDepositRebalanceRedeem() public {
        Deploy.Deployed memory d = _deploy();
        _seed(d); // seed at the real fork timestamp, then move into a session
        _toSession(d);

        ISignalEngine.Signal memory s = d.engine.computeSignal();
        console2.log("riskOn", s.riskOn, "historyDays", s.historyDays);
        console2.log("basketRatioLong (1e18=MA)", s.basketRatioLong);
        console2.log("basketVolBps", s.basketVolBps, "stockScaleBps", s.stockScaleBps);
        console2.log("goldRatioLong", s.goldRatioLong, "goldShareBps", s.goldShareBps);
        assertGe(s.historyDays, 50, "seeding should give >= 50 sessions on day one");

        RotationVault bold = RotationVault(d.bold);
        RotationVault steady = RotationVault(d.steady);
        _fund(alice, 6_000e6);
        vm.startPrank(alice);
        IERC20(RH.USDG).approve(address(bold), type(uint256).max);
        IERC20(RH.USDG).approve(address(steady), type(uint256).max);
        bold.deposit(3_000e6, alice);
        steady.deposit(3_000e6, alice);
        vm.stopPrank();
        assertApproxEqAbs(bold.totalAssets(), 3_000e6, 1);

        _rebalance(bold);
        _rebalance(steady);

        uint256 boldStock = bold.stockWeightBps();
        uint256 steadyStock = steady.stockWeightBps();
        console2.log("bold stock bps", boldStock, "steady stock bps", steadyStock);
        assertLe(steadyStock, 4000);
        assertLe(boldStock, 10_000);
        if (s.riskOn) assertGt(boldStock, 0);
        else assertEq(boldStock, 0);
        (address[] memory a,, uint256[] memory w,, uint256 nav) = bold.allocation();
        for (uint256 i; i < a.length; ++i) console2.log(IERC20Metadata(a[i]).symbol(), w[i]);
        console2.log("bold NAV", nav);
        // real round-trip costs (pool fees + spread) stay small
        assertGt(nav, 2_940e6, "rebalance lost > 2 % of NAV");

        // exits: in-kind always, cash up to idle
        uint256 shares = bold.balanceOf(alice);
        vm.prank(alice);
        bold.redeemInKind(shares / 2, alice, alice);
        uint256 maxCash = bold.maxRedeem(alice);
        vm.prank(alice);
        bold.redeem(maxCash, alice, alice);
        assertGt(IERC20(RH.USDG).balanceOf(alice), 0);
    }

    function _rebalance(RotationVault v) internal {
        vm.prank(keeper);
        v.startRebalance();
        uint8 n = v.chunkCount();
        for (uint256 i; i < n; ++i) {
            if (i > 0) {
                vm.warp(block.timestamp + v.chunkInterval());
                _heartbeat();
            }
            vm.prank(keeper);
            v.executeChunk(block.timestamp + 5 minutes);
        }
    }

    function test_fork_dexAdapterFillsNearOracle() public {
        Deploy.Deployed memory d = _deploy();
        _heartbeat();
        address[4] memory assets = [RH.SPY, RH.QQQ, RH.GLD, RH.SGOV];
        _fund(address(this), 400e6);
        IERC20(RH.USDG).approve(address(d.dex), type(uint256).max);
        (uint256 usdgPx,) = d.oracle.getPrice(RH.USDG);
        for (uint256 i; i < 4; ++i) {
            (uint256 px,) = d.oracle.getPrice(assets[i]);
            uint256 fair = (100e6 * usdgPx * 1e12) / px; // tokens (18d) for 100 USDG at oracle
            uint256 out = d.dex.swapExactIn(RH.USDG, assets[i], 100e6, (fair * 97) / 100, address(this), block.timestamp);
            console2.log(IERC20Metadata(assets[i]).symbol(), "fill vs oracle (bps)", (out * 10_000) / fair);
            assertGt(out, (fair * 97) / 100);
        }
    }
}

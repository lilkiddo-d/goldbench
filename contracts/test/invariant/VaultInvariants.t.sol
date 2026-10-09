// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {RotationVault} from "../../src/vault/RotationVault.sol";
import {MockERC20, MockAggregator} from "../mocks/Mocks.sol";
import {MarketClock} from "../../src/market/MarketClock.sol";
import {PriceHistory} from "../../src/signal/PriceHistory.sol";

contract VaultHandler is Test {
    RotationVault[3] public vaults;
    MockERC20 public usdg;
    MarketClock public clock;
    PriceHistory public history;
    MockAggregator[4] public feeds; // spy, qqq, gld, sgov
    MockAggregator public fUsdg;
    address public keeper;
    address[3] public actors;

    bool public capBreached;
    bool public diluted;
    uint256 public deposits;
    uint256 public chunks;
    uint256 public maxObservedStockOverCap;

    constructor(
        RotationVault[3] memory v,
        MockERC20 u,
        MarketClock c,
        PriceHistory h,
        MockAggregator[4] memory f,
        MockAggregator fu,
        address k
    ) {
        vaults = v;
        usdg = u;
        clock = c;
        history = h;
        feeds = f;
        fUsdg = fu;
        keeper = k;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];
    }

    function _refresh() internal {
        for (uint256 i; i < 4; ++i) {
            (, int256 p,,,) = feeds[i].latestRoundData();
            feeds[i].setPrice(p);
        }
        fUsdg.setPrice(1e8);
    }

    function deposit(uint256 vaultSeed, uint256 actorSeed, uint256 amount) external {
        RotationVault v = vaults[vaultSeed % 3];
        address a = actors[actorSeed % 3];
        amount = bound(amount, 1e6, 1_000_000e6);
        v.accrueFees();
        uint256 ppsBefore = v.totalSupply() == 0 ? 0 : v.convertToAssets(1e12);
        usdg.mint(a, amount);
        vm.startPrank(a);
        usdg.approve(address(v), amount);
        try v.deposit(amount, a) {
            deposits++;
            uint256 ppsAfter = v.convertToAssets(1e12);
            if (ppsBefore != 0 && ppsAfter < ppsBefore) diluted = true;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 vaultSeed, uint256 actorSeed, uint256 frac) external {
        RotationVault v = vaults[vaultSeed % 3];
        address a = actors[actorSeed % 3];
        uint256 shares = (v.maxRedeem(a) * bound(frac, 1, 100)) / 100;
        if (shares == 0) return;
        vm.prank(a);
        try v.redeem(shares, a, a) {} catch {}
    }

    function redeemInKind(uint256 vaultSeed, uint256 actorSeed, uint256 frac) external {
        RotationVault v = vaults[vaultSeed % 3];
        address a = actors[actorSeed % 3];
        uint256 shares = (v.balanceOf(a) * bound(frac, 1, 100)) / 100;
        if (shares == 0) return;
        vm.prank(a);
        v.redeemInKind(shares, a, a);
    }

    function movePrices(uint256 seed) external {
        for (uint256 i; i < 4; ++i) {
            (, int256 p,,,) = feeds[i].latestRoundData();
            int256 move = int256(uint256(keccak256(abi.encode(seed, i))) % 601) - 300; // ±3 %
            feeds[i].setPrice((p * (10_000 + move)) / 10_000);
        }
    }

    function recordDay() external {
        uint256 today = clock.etDay(block.timestamp);
        uint256 d = today + 1;
        while (!clock.isTradingDay(d)) d++;
        vm.warp(clock.closeTimestamp(d) + 5 minutes);
        _refresh();
        vm.prank(keeper);
        history.recordDailyCloses();
    }

    function rebalance(uint256 vaultSeed) external {
        RotationVault v = vaults[vaultSeed % 3];
        uint256 today = clock.etDay(block.timestamp);
        uint256 d = today + 1;
        while (!clock.isTradingDay(d)) d++;
        vm.warp(clock.closeTimestamp(d) - 2 hours - 30 minutes);
        _refresh();
        vm.prank(keeper);
        try v.startRebalance() {}
        catch {
            return;
        }
        uint8 n = v.chunkCount();
        for (uint256 i; i < n; ++i) {
            if (i > 0) {
                vm.warp(block.timestamp + v.chunkInterval());
                _refresh();
            }
            uint256 stockBefore = v.stockWeightBps();
            vm.prank(keeper);
            try v.executeChunk(block.timestamp + 60) {
                chunks++;
                uint256 w = v.stockWeightBps();
                // a chunk may only *reduce* an over-cap position (after passive price drift), never add to it
                if (w > v.stockCapBps() && w > stockBefore) {
                    capBreached = true;
                    if (w - v.stockCapBps() > maxObservedStockOverCap) maxObservedStockOverCap = w - v.stockCapBps();
                }
            } catch {}
        }
    }
}

contract VaultInvariants is Fixture {
    VaultHandler handler;

    function setUp() public override {
        super.setUp();
        _buildHistory(210, 6, 2, 25);
        handler = new VaultHandler(
            [steady, balanced, bold],
            usdg,
            clock,
            history,
            [fSpy, fQqq, fGld, fSgov],
            fUsdg,
            keeper
        );
        targetContract(address(handler));
        // seed some TVL so rebalances trade
        _deposit(steady, alice, 100_000e6);
        _deposit(balanced, alice, 100_000e6);
        _deposit(bold, alice, 100_000e6);
    }

    function afterInvariant() public view {
        console2.log("deposits", handler.deposits(), "chunks", handler.chunks());
    }

    /// @notice Spec: allocations never exceed each vault's stock cap.
    function invariant_stockCapNeverExceededByTrading() public view {
        assertFalse(handler.capBreached(), "a rebalance chunk pushed stock weight above the vault cap");
    }

    /// @notice Spec: deposits never dilute existing holders.
    function invariant_depositsNeverDilute() public view {
        assertFalse(handler.diluted(), "a deposit reduced price-per-share");
    }

    /// @notice Planned stock targets are always within the cap.
    function invariant_targetsWithinCap() public view {
        RotationVault[3] memory vs = [steady, balanced, bold];
        for (uint256 j; j < 3; ++j) {
            address[] memory h = vs[j].holdings();
            uint256 stockTarget;
            uint256 total;
            for (uint256 i; i < h.length; ++i) {
                total += vs[j].targetBps(h[i]);
                if (vs[j].isStockAsset(h[i])) stockTarget += vs[j].targetBps(h[i]);
            }
            assertLe(stockTarget, vs[j].stockCapBps());
            assertLe(total, 10_000);
        }
    }

    /// @notice Shares are always backed: no supply without assets.
    function invariant_supplyBacked() public view {
        RotationVault[3] memory vs = [steady, balanced, bold];
        for (uint256 j; j < 3; ++j) {
            if (vs[j].totalSupply() > 0) assertGt(vs[j].totalAssets(), 0);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20, MockStockToken, MockAggregator, MockSwapRouter} from "./mocks/Mocks.sol";
import {MarketClock} from "../src/market/MarketClock.sol";
import {ChainlinkOracleAdapter} from "../src/oracle/ChainlinkOracleAdapter.sol";
import {PriceHistory} from "../src/signal/PriceHistory.sol";
import {SignalEngine} from "../src/signal/SignalEngine.sol";
import {Allocator} from "../src/signal/Allocator.sol";
import {UniswapV3DexAdapter} from "../src/dex/UniswapV3DexAdapter.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {FeeCollector} from "../src/fees/FeeCollector.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {ProjectTokenHooks} from "../src/token/ProjectTokenHooks.sol";
import {RotationVault} from "../src/vault/RotationVault.sol";
import {VaultFactory, IRegistrar, IHooksRegistrar} from "../src/vault/VaultFactory.sol";
import {IOracleAdapter, IMarketClock, IPriceHistory, ISignalEngine, IAllocator, IDexAdapter, IComplianceRegistry} from
    "../src/interfaces/IGoldbench.sol";
import {ISwapRouter02} from "../src/interfaces/IExternal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract Fixture is Test {
    uint256 internal constant START = 1735776000; // 2025-01-02 00:00 UTC (Thursday)

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal usdg;
    MockStockToken internal spy;
    MockStockToken internal qqq;
    MockStockToken internal gld;
    MockStockToken internal sgov;
    MockAggregator internal fUsdg;
    MockAggregator internal fSpy;
    MockAggregator internal fQqq;
    MockAggregator internal fGld;
    MockAggregator internal fSgov;

    MarketClock internal clock;
    ChainlinkOracleAdapter internal oracle;
    PriceHistory internal history;
    SignalEngine internal engine;
    Allocator internal allocator;
    MockSwapRouter internal router;
    UniswapV3DexAdapter internal dex;
    ComplianceRegistry internal compliance;
    FeeCollector internal fees;
    Timelock internal timelock;
    ProjectTokenHooks internal hooks;
    RotationVault internal impl;
    VaultFactory internal factory;
    RotationVault internal steady;
    RotationVault internal balanced;
    RotationVault internal bold;

    // current synthetic prices (8 decimals, Chainlink style)
    int256 internal pSpy = 500e8;
    int256 internal pQqq = 450e8;
    int256 internal pGld = 250e8;
    int256 internal pSgov = 100e8;
    int256 internal pUsdg = 1e8;

    function setUp() public virtual {
        vm.warp(START);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        spy = new MockStockToken("SPY token", "SPY");
        qqq = new MockStockToken("QQQ token", "QQQ");
        gld = new MockStockToken("GLD token", "GLD");
        sgov = new MockStockToken("SGOV token", "SGOV");
        fUsdg = new MockAggregator(8);
        fSpy = new MockAggregator(8);
        fQqq = new MockAggregator(8);
        fGld = new MockAggregator(8);
        fSgov = new MockAggregator(8);
        _pushPrices();

        vm.startPrank(admin);
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new Timelock(48 hours, proposers, executors, address(0));

        clock = new MarketClock(admin);
        oracle = new ChainlinkOracleAdapter(admin);
        oracle.setFeed(address(usdg), address(fUsdg), 3 days, false);
        oracle.setFeed(address(spy), address(fSpy), 3 days, true);
        oracle.setFeed(address(qqq), address(fQqq), 3 days, true);
        oracle.setFeed(address(gld), address(fGld), 3 days, true);
        oracle.setFeed(address(sgov), address(fSgov), 3 days, true);

        history = new PriceHistory(admin, IOracleAdapter(address(oracle)), IMarketClock(address(clock)));
        history.addAsset(address(spy));
        history.addAsset(address(qqq));
        history.addAsset(address(gld));
        history.addAsset(address(sgov));
        history.grantRole(history.KEEPER_ROLE(), keeper);

        engine = new SignalEngine(admin, IPriceHistory(address(history)));
        address[] memory b = new address[](2);
        b[0] = address(spy);
        b[1] = address(qqq);
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        engine.setBasket(b, w);
        engine.setDefensiveAssets(address(gld), address(sgov));
        allocator = new Allocator(ISignalEngine(address(engine)));

        router = new MockSwapRouter();
        router.setToken(address(usdg), fUsdg, 6);
        router.setToken(address(spy), fSpy, 18);
        router.setToken(address(qqq), fQqq, 18);
        router.setToken(address(gld), fGld, 18);
        router.setToken(address(sgov), fSgov, 18);
        dex = new UniswapV3DexAdapter(admin, ISwapRouter02(address(router)), address(usdg));
        dex.setPoolFee(address(spy), 500);
        dex.setPoolFee(address(qqq), 500);
        dex.setPoolFee(address(gld), 3000);
        dex.setPoolFee(address(sgov), 3000);

        compliance = new ComplianceRegistry(admin);
        compliance.grantRole(compliance.COMPLIANCE_ROLE(), admin);
        fees = new FeeCollector(admin, treasury);
        hooks = new ProjectTokenHooks(admin, ISignalEngine(address(engine)), timelock);
        fees.setHooks(hooks);
        hooks.setFeeCollector(address(fees));

        impl = new RotationVault();
        factory = new VaultFactory(
            admin, address(impl), engine, IRegistrar(address(fees)), IHooksRegistrar(address(hooks))
        );
        engine.grantRole(engine.REGISTRAR_ROLE(), address(factory));
        fees.grantRole(fees.REGISTRAR_ROLE(), address(factory));
        hooks.grantRole(hooks.REGISTRAR_ROLE(), address(factory));

        steady = RotationVault(factory.createVault(_params("Goldbench Steady", "gbSTEADY", 4000)));
        balanced = RotationVault(factory.createVault(_params("Goldbench Balanced", "gbBAL", 7000)));
        bold = RotationVault(factory.createVault(_params("Goldbench Bold", "gbBOLD", 10_000)));
        vm.stopPrank();

        vm.label(address(steady), "Steady");
        vm.label(address(balanced), "Balanced");
        vm.label(address(bold), "Bold");
    }

    function _params(string memory n, string memory s, uint16 cap) internal view returns (RotationVault.InitParams memory) {
        return RotationVault.InitParams({
            name: n,
            symbol: s,
            base: IERC20(address(usdg)),
            stockCapBps: cap,
            admin: admin,
            guardian: guardian,
            keeper: keeper,
            depositCap: 10_000_000e6,
            modules: RotationVault.Modules({
                engine: ISignalEngine(address(engine)),
                allocator: IAllocator(address(allocator)),
                dex: IDexAdapter(address(dex)),
                clock: IMarketClock(address(clock)),
                oracle: IOracleAdapter(address(oracle)),
                history: IPriceHistory(address(history)),
                feeCollector: address(fees),
                compliance: IComplianceRegistry(address(compliance))
            })
        });
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _pushPrices() internal {
        fUsdg.setPrice(pUsdg);
        fSpy.setPrice(pSpy);
        fQqq.setPrice(pQqq);
        fGld.setPrice(pGld);
        fSgov.setPrice(pSgov);
    }

    function _nextTradingDay(uint256 day) internal view returns (uint256 d) {
        d = day + 1;
        while (!clock.isTradingDay(d)) d++;
    }

    /// @dev Advance to the next session close, push current prices, record closes.
    function _recordNextDay() internal {
        uint256 today = clock.etDay(block.timestamp);
        uint256 d = clock.isTradingDay(today) && block.timestamp < clock.closeTimestamp(today) ? today : _nextTradingDay(today);
        vm.warp(clock.closeTimestamp(d) + 5 minutes);
        _pushPrices();
        vm.prank(keeper);
        history.recordDailyCloses();
    }

    /// @dev Build `n` trading days of history with constant daily drifts (bps, signed) and small deterministic noise.
    function _buildHistory(uint256 n, int256 stockDriftBps, int256 goldDriftBps, uint256 noiseBps) internal {
        for (uint256 i; i < n; ++i) {
            int256 noise = noiseBps == 0
                ? int256(0)
                : int256(uint256(keccak256(abi.encode(i, block.timestamp))) % (2 * noiseBps + 1)) - int256(noiseBps);
            pSpy = (pSpy * (10_000 + stockDriftBps + noise)) / 10_000;
            pQqq = (pQqq * (10_000 + stockDriftBps - noise)) / 10_000;
            pGld = (pGld * (10_000 + goldDriftBps + noise / 2)) / 10_000;
            pSgov = (pSgov * 10_001) / 10_000;
            _recordNextDay();
        }
    }

    /// @dev Warp into the next regular session (14:00 New York) and refresh oracle timestamps.
    function _warpToOpen() internal {
        uint256 today = clock.etDay(block.timestamp);
        uint256 d = clock.isTradingDay(today) && block.timestamp < clock.closeTimestamp(today) - 2 hours
            ? today
            : _nextTradingDay(today);
        vm.warp(clock.closeTimestamp(d) - 2 hours);
        _pushPrices();
    }

    function _deposit(RotationVault v, address who, uint256 amount) internal returns (uint256 shares) {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(v), amount);
        shares = v.deposit(amount, who);
        vm.stopPrank();
    }

    function _runFullRebalance(RotationVault v) internal {
        _warpToOpen();
        vm.prank(keeper);
        v.startRebalance();
        uint8 total = v.chunkCount();
        for (uint256 i; i < total; ++i) {
            if (i > 0) {
                vm.warp(block.timestamp + v.chunkInterval());
                _pushPrices();
            }
            vm.prank(keeper);
            v.executeChunk(block.timestamp + 5 minutes);
        }
    }
}

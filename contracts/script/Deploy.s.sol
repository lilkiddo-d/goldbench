// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {RobinhoodMainnet as RH} from "./Addresses.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {MarketClock} from "../src/market/MarketClock.sol";
import {ChainlinkOracleAdapter} from "../src/oracle/ChainlinkOracleAdapter.sol";
import {PriceHistory} from "../src/signal/PriceHistory.sol";
import {SignalEngine} from "../src/signal/SignalEngine.sol";
import {Allocator} from "../src/signal/Allocator.sol";
import {UniswapV3DexAdapter} from "../src/dex/UniswapV3DexAdapter.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {FeeCollector} from "../src/fees/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/token/ProjectTokenHooks.sol";
import {RotationVault} from "../src/vault/RotationVault.sol";
import {VaultFactory, IRegistrar, IHooksRegistrar} from "../src/vault/VaultFactory.sol";
import {
    IOracleAdapter,
    IMarketClock,
    IPriceHistory,
    ISignalEngine,
    IAllocator,
    IDexAdapter,
    IComplianceRegistry
} from "../src/interfaces/IGoldbench.sol";
import {ISwapRouter02} from "../src/interfaces/IExternal.sol";

/// @title Deploy
/// @notice One-shot deployment of the entire Goldbench protocol on Robinhood Chain (or a fork of it):
///         deploys + wires every contract, creates the Steady/Balanced/Bold vaults, hands DEFAULT_ADMIN_ROLE of
///         everything to the 48h Timelock, renounces the deployer, asserts the handoff, and writes
///         deployments/<chainId>.json plus app/src/config/deployments.<chainId>.json.
///
///   Signing: only through a Foundry keystore (`--account goldbench-deployer`). This script never reads a key.
///   Env (all optional except where noted):
///     GOLDBENCH_OWNER     multisig that proposes/cancels on the Timelock      (default: deployer)
///     GOLDBENCH_GUARDIAN  can pause + declare emergency market closures         (default: owner)
///     GOLDBENCH_KEEPER    keeper EOA (`cast wallet address --account goldbench-keeper`) — REQUIRED on mainnet
///     GOLDBENCH_TREASURY  receives management fees                              (default: owner)
///     GOLDBENCH_DEPOSIT_CAP  per-vault TVL cap in USDG base units               (default: 250,000 USDG)
contract Deploy is Script {
    struct Deployed {
        Timelock timelock;
        MarketClock clock;
        ChainlinkOracleAdapter oracle;
        PriceHistory history;
        SignalEngine engine;
        Allocator allocator;
        UniswapV3DexAdapter dex;
        ComplianceRegistry compliance;
        FeeCollector fees;
        ProjectTokenHooks hooks;
        RotationVault implementation;
        VaultFactory factory;
        address steady;
        address balanced;
        address bold;
    }

    struct Roles {
        address deployer;
        address owner;
        address guardian;
        address keeper;
        address treasury;
        uint256 depositCap;
    }

    uint32 internal constant STOCK_STALENESS = 30 hours;
    uint32 internal constant CRYPTO_STALENESS = 30 hours;

    function run() external returns (Deployed memory d) {
        require(block.chainid == RH.CHAIN_ID, "Deploy: not Robinhood Chain (use a fork of 4663)");
        Roles memory r = _roles();

        vm.startBroadcast();
        d = _deployCore(r);
        _configure(d, r);
        _createVaults(d, r);
        _handoff(d, r);
        vm.stopBroadcast();

        _assertHandoff(d, r);
        _writeOutputs(d, r);
    }

    // ───────────────────────────── steps ─────────────────────────────

    function _roles() internal view returns (Roles memory r) {
        (, address sender,) = vm.readCallers();
        r.deployer = sender;
        r.owner = vm.envOr("GOLDBENCH_OWNER", sender);
        r.guardian = vm.envOr("GOLDBENCH_GUARDIAN", r.owner);
        r.treasury = vm.envOr("GOLDBENCH_TREASURY", r.owner);
        r.keeper = vm.envOr("GOLDBENCH_KEEPER", address(0));
        r.depositCap = vm.envOr("GOLDBENCH_DEPOSIT_CAP", uint256(250_000e6));
        require(r.keeper != address(0), "Deploy: set GOLDBENCH_KEEPER (cast wallet address --account goldbench-keeper)");
        console2.log("deployer", r.deployer);
        console2.log("owner   ", r.owner);
        console2.log("guardian", r.guardian);
        console2.log("keeper  ", r.keeper);
        console2.log("treasury", r.treasury);
    }

    function _deployCore(Roles memory r) internal returns (Deployed memory d) {
        address[] memory proposers = new address[](1);
        proposers[0] = r.owner;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a matured operation
        // deployer is temporary timelock admin only to grant PROPOSER_ROLE to ProjectTokenHooks; renounced below
        d.timelock = new Timelock(48 hours, proposers, executors, r.deployer);

        d.clock = new MarketClock(r.deployer);
        d.oracle = new ChainlinkOracleAdapter(r.deployer);
        d.history = new PriceHistory(r.deployer, IOracleAdapter(address(d.oracle)), IMarketClock(address(d.clock)));
        d.engine = new SignalEngine(r.deployer, IPriceHistory(address(d.history)));
        d.allocator = new Allocator(ISignalEngine(address(d.engine)));
        d.dex = new UniswapV3DexAdapter(r.deployer, ISwapRouter02(RH.SWAP_ROUTER_02), RH.USDG);
        d.compliance = new ComplianceRegistry(r.deployer);
        d.fees = new FeeCollector(r.deployer, r.treasury);
        d.hooks = new ProjectTokenHooks(r.deployer, ISignalEngine(address(d.engine)), d.timelock);
        d.implementation = new RotationVault();
        d.factory = new VaultFactory(
            r.deployer,
            address(d.implementation),
            d.engine,
            IRegistrar(address(d.fees)),
            IHooksRegistrar(address(d.hooks))
        );
    }

    function _configure(Deployed memory d, Roles memory r) internal {
        // market calendar (NYSE full closures + 13:00 early closes, 2026–2027); maintained yearly via Timelock
        d.clock.setHolidays(_holidays(), true);
        d.clock.setEarlyClose(20784, 13 * 60); // 2026-11-27
        d.clock.setEarlyClose(20811, 13 * 60); // 2026-12-24
        d.clock.setEarlyClose(21148, 13 * 60); // 2027-11-26

        // oracle feeds (Chainlink, 8 decimals, 24h heartbeat)
        d.oracle.setFeed(RH.USDG, RH.USDG_USD_FEED, CRYPTO_STALENESS, false);
        d.oracle.setFeed(RH.SPY, RH.SPY_USD_FEED, STOCK_STALENESS, true);
        d.oracle.setFeed(RH.QQQ, RH.QQQ_USD_FEED, STOCK_STALENESS, true);
        d.oracle.setFeed(RH.GLD, RH.GLD_USD_FEED, CRYPTO_STALENESS, true);
        d.oracle.setFeed(RH.SGOV, RH.SGOV_USD_FEED, STOCK_STALENESS, true);
        if (RH.SEQUENCER_UPTIME_FEED != address(0)) d.oracle.setSequencerFeed(RH.SEQUENCER_UPTIME_FEED, 1 hours);

        // price history + signal
        d.history.addAsset(RH.SPY);
        d.history.addAsset(RH.QQQ);
        d.history.addAsset(RH.GLD);
        d.history.addAsset(RH.SGOV);
        d.history.grantRole(d.history.KEEPER_ROLE(), r.keeper);

        address[] memory basket = new address[](2);
        basket[0] = RH.SPY;
        basket[1] = RH.QQQ;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        d.engine.setBasket(basket, w);
        d.engine.setDefensiveAssets(RH.GLD, RH.SGOV);

        // execution venue
        d.dex.setPoolFee(RH.SPY, RH.SPY_POOL_FEE);
        d.dex.setPoolFee(RH.QQQ, RH.QQQ_POOL_FEE);
        d.dex.setPoolFee(RH.GLD, RH.GLD_POOL_FEE);
        d.dex.setPoolFee(RH.SGOV, RH.SGOV_POOL_FEE);

        // fees / token hooks wiring (token features stay disabled until setProjectToken)
        d.fees.setHooks(d.hooks);
        d.hooks.setFeeCollector(address(d.fees));
        d.compliance.grantRole(d.compliance.COMPLIANCE_ROLE(), r.owner);

        // factory registrar powers
        d.engine.grantRole(d.engine.REGISTRAR_ROLE(), address(d.factory));
        d.fees.grantRole(d.fees.REGISTRAR_ROLE(), address(d.factory));
        d.hooks.grantRole(d.hooks.REGISTRAR_ROLE(), address(d.factory));

        // guardians
        d.clock.grantRole(d.clock.GUARDIAN_ROLE(), r.guardian);
        d.oracle.grantRole(d.oracle.GUARDIAN_ROLE(), r.guardian);
        d.history.grantRole(d.history.GUARDIAN_ROLE(), r.guardian);
        d.engine.grantRole(d.engine.GUARDIAN_ROLE(), r.guardian);
        d.dex.grantRole(d.dex.GUARDIAN_ROLE(), r.guardian);
        d.fees.grantRole(d.fees.GUARDIAN_ROLE(), r.guardian);
        d.hooks.grantRole(d.hooks.GUARDIAN_ROLE(), r.guardian);
        d.compliance.grantRole(d.compliance.GUARDIAN_ROLE(), r.guardian);

        // staker votes can be *scheduled* (48h delay, owner can cancel); inert until the project token is set
        d.timelock.grantRole(d.timelock.PROPOSER_ROLE(), address(d.hooks));
    }

    function _createVaults(Deployed memory d, Roles memory r) internal {
        d.steady = d.factory.createVault(_vaultParams(d, r, "Goldbench Steady", "gbSTEADY", 4000));
        d.balanced = d.factory.createVault(_vaultParams(d, r, "Goldbench Balanced", "gbBALANCED", 7000));
        d.bold = d.factory.createVault(_vaultParams(d, r, "Goldbench Bold", "gbBOLD", 10_000));
    }

    function _vaultParams(Deployed memory d, Roles memory r, string memory name, string memory symbol, uint16 cap)
        internal
        pure
        returns (RotationVault.InitParams memory)
    {
        return RotationVault.InitParams({
            name: name,
            symbol: symbol,
            base: IERC20(RH.USDG),
            stockCapBps: cap,
            admin: address(d.timelock), // vault admin is the Timelock from block one
            guardian: r.guardian,
            keeper: r.keeper,
            depositCap: r.depositCap,
            modules: RotationVault.Modules({
                engine: ISignalEngine(address(d.engine)),
                allocator: IAllocator(address(d.allocator)),
                dex: IDexAdapter(address(d.dex)),
                clock: IMarketClock(address(d.clock)),
                oracle: IOracleAdapter(address(d.oracle)),
                history: IPriceHistory(address(d.history)),
                feeCollector: address(d.fees),
                compliance: IComplianceRegistry(address(d.compliance)) // registry is disabled by default
            })
        });
    }

    function _handoff(Deployed memory d, Roles memory r) internal {
        AccessControl[9] memory all = _accessControlled(d);
        bytes32 adminRole = 0x00;
        for (uint256 i; i < all.length; ++i) {
            all[i].grantRole(adminRole, address(d.timelock));
            all[i].renounceRole(adminRole, r.deployer);
        }
        d.timelock.renounceRole(adminRole, r.deployer);
    }

    function _assertHandoff(Deployed memory d, Roles memory r) internal view {
        AccessControl[9] memory all = _accessControlled(d);
        for (uint256 i; i < all.length; ++i) {
            require(all[i].hasRole(0x00, address(d.timelock)), "handoff: timelock not admin");
            if (r.deployer != address(d.timelock)) {
                require(!all[i].hasRole(0x00, r.deployer), "handoff: deployer still admin");
            }
        }
        address[3] memory vs = [d.steady, d.balanced, d.bold];
        for (uint256 i; i < 3; ++i) {
            require(AccessControl(vs[i]).hasRole(0x00, address(d.timelock)), "handoff: vault admin");
            require(!AccessControl(vs[i]).hasRole(0x00, r.deployer) || r.deployer == address(d.timelock), "vault");
        }
        require(!d.timelock.hasRole(0x00, r.deployer), "handoff: deployer still timelock admin");
        require(d.timelock.getMinDelay() == 48 hours, "handoff: delay");
        require(d.hooks.projectToken() == address(0), "token must not be set at deploy");
    }

    function _accessControlled(Deployed memory d) internal pure returns (AccessControl[9] memory) {
        return [
            AccessControl(address(d.clock)),
            AccessControl(address(d.oracle)),
            AccessControl(address(d.history)),
            AccessControl(address(d.engine)),
            AccessControl(address(d.dex)),
            AccessControl(address(d.compliance)),
            AccessControl(address(d.fees)),
            AccessControl(address(d.hooks)),
            AccessControl(address(d.factory))
        ];
    }

    function _holidays() internal pure returns (uint256[] memory h) {
        h = new uint256[](20);
        // 2026: Jan 1, Jan 19, Feb 16, Apr 3, May 25, Jun 19, Jul 3, Sep 7, Nov 26, Dec 25
        h[0] = 20454;
        h[1] = 20472;
        h[2] = 20500;
        h[3] = 20546;
        h[4] = 20598;
        h[5] = 20623;
        h[6] = 20637;
        h[7] = 20703;
        h[8] = 20783;
        h[9] = 20812;
        // 2027: Jan 1, Jan 18, Feb 15, Mar 26, May 31, Jun 18, Jul 5, Sep 6, Nov 25, Dec 24
        h[10] = 20819;
        h[11] = 20836;
        h[12] = 20864;
        h[13] = 20903;
        h[14] = 20969;
        h[15] = 20987;
        h[16] = 21004;
        h[17] = 21067;
        h[18] = 21147;
        h[19] = 21176;
    }

    // ───────────────────────────── outputs ─────────────────────────────

    function _writeOutputs(Deployed memory d, Roles memory r) internal {
        if (!vm.envOr("GOLDBENCH_WRITE_OUTPUTS", true)) return;
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAtBlock", block.number);
        vm.serializeAddress(k, "timelock", address(d.timelock));
        vm.serializeAddress(k, "marketClock", address(d.clock));
        vm.serializeAddress(k, "oracleAdapter", address(d.oracle));
        vm.serializeAddress(k, "priceHistory", address(d.history));
        vm.serializeAddress(k, "signalEngine", address(d.engine));
        vm.serializeAddress(k, "allocator", address(d.allocator));
        vm.serializeAddress(k, "dexAdapter", address(d.dex));
        vm.serializeAddress(k, "complianceRegistry", address(d.compliance));
        vm.serializeAddress(k, "feeCollector", address(d.fees));
        vm.serializeAddress(k, "projectTokenHooks", address(d.hooks));
        vm.serializeAddress(k, "vaultImplementation", address(d.implementation));
        vm.serializeAddress(k, "vaultFactory", address(d.factory));
        vm.serializeAddress(k, "vaultSteady", d.steady);
        vm.serializeAddress(k, "vaultBalanced", d.balanced);
        vm.serializeAddress(k, "vaultBold", d.bold);
        vm.serializeAddress(k, "owner", r.owner);
        vm.serializeAddress(k, "guardian", r.guardian);
        vm.serializeAddress(k, "keeper", r.keeper);
        vm.serializeAddress(k, "treasury", r.treasury);
        vm.serializeAddress(k, "usdg", RH.USDG);
        vm.serializeAddress(k, "spy", RH.SPY);
        vm.serializeAddress(k, "qqq", RH.QQQ);
        vm.serializeAddress(k, "gld", RH.GLD);
        string memory json = vm.serializeAddress(k, "sgov", RH.SGOV);

        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory suffix = broadcast ? "" : ".dryrun";
        string memory id = vm.toString(block.chainid);
        string memory local = vm.envOr("GOLDBENCH_DEPLOYMENT_TAG", string(""));
        if (bytes(local).length != 0) id = string.concat(id, "-", local);
        vm.writeJson(json, string.concat(vm.projectRoot(), "/../deployments/", id, suffix, ".json"));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/../app/src/config/deployments.", id, suffix, ".json"));
        console2.log("wrote deployments/%s%s.json", id, suffix);
    }
}

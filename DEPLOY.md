# DEPLOY — exactly what you run

Everything signs through **Foundry keystores**. No private key or seed phrase is ever created, requested, stored or printed by this repo. Run commands from the repo root unless noted (`cd contracts` where shown).

Prerequisites: Foundry ≥ 1.8, Node ≥ 20, pnpm ≥ 9, `pnpm install` at the repo root. The deployer account needs ~0.02 ETH on Robinhood Chain for gas; the keeper a little ETH too.

> **Windows note:** on the build machine Windows *Smart App Control / Application Control* blocked `cast.exe` (forge and anvil still ran). If `cast` refuses to start, allow it in *Windows Security → App & browser control*, re-run `foundryup`, or run the `cast` steps from WSL. Nothing else in this guide needs `cast`.

## Pre-flight checklist (mainnet)

- [ ] **Owner = a multisig (Safe) on Robinhood Chain.** It becomes the only Timelock proposer/canceller and the fee treasury. Don't use the deployer EOA.
- [ ] **Deployer funded:** the dry run estimates ~27M gas ≈ 0.0011 ETH at 0.04 gwei; keep 0.01 ETH for headroom and verification retries.
- [ ] **Keeper funded:** ~0.01 ETH (seeding plus daily recordings and weekly rebalances).
- [ ] **Run steps 2 → seed on a weekday**, ideally during or right after US market hours. Stock feeds are 24/5, and seeding needs a fresh live price as its sanity reference.
- [ ] **Seed BEFORE starting the keeper.** The first daily recording permanently closes seeding.
- [ ] **Use a private RPC** (e.g. Alchemy) for deploy + keeper if possible: `--rpc-url $ROBINHOOD_RPC_URL`. The public endpoint rate-limits and showed Cloudflare challenges during testing.
- [ ] **Verification:** Blockscout's API was also behind a Cloudflare challenge at times. If `--verify` fails, the deploy is still complete; re-run the same command with `--resume`, or verify later with `forge verify-contract <addr> <path:Contract> --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --chain 4663`.
- [ ] **After deploy, commit** `deployments/4663.json` and `app/src/config/deployments.4663.json` (the app ships a placeholder until then).

---

## 1. Import the deployer key into an encrypted keystore (once)

```bash
cast wallet import goldbench-deployer --interactive
```

Also create the keeper account the same way (it signs daily price recordings and rebalances):

```bash
cast wallet import goldbench-keeper --interactive
```

Look up the keeper address (needed in step 2):

```bash
cast wallet address --account goldbench-keeper
```

## 2. Deploy + verify (one command)

Replace `<OWNER_SAFE>` with the multisig that will propose/cancel on the 48h Timelock and receive fees, and `<KEEPER_ADDRESS>` with the address from step 1. (`GOLDBENCH_GUARDIAN` defaults to the owner; add it to use a separate pause key.)

```bash
cd contracts && GOLDBENCH_OWNER=<OWNER_SAFE> GOLDBENCH_KEEPER=<KEEPER_ADDRESS> forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account goldbench-deployer --broadcast --slow --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

What it does (all in one script, asserted at the end):
- deploys Timelock (48h, hard floor), MarketClock (+ NYSE holidays 2026–27), ChainlinkOracleAdapter (+ 5 feeds), PriceHistory, SignalEngine (SPY 60 / QQQ 40, GLD, SGOV), Allocator, UniswapV3DexAdapter (+ fee tiers), ComplianceRegistry (**disabled**), FeeCollector, ProjectTokenHooks (**token unset**), RotationVault implementation, VaultFactory, and the **Steady / Balanced / Bold** vaults (deposit cap 250,000 USDG each; override with `GOLDBENCH_DEPOSIT_CAP`);
- grants KEEPER/GUARDIAN roles, hands `DEFAULT_ADMIN_ROLE` of every contract to the Timelock, renounces the deployer, and reverts if anything is left behind;
- verifies every contract on Blockscout;
- writes `deployments/4663.json` **and** `app/src/config/deployments.4663.json` (the frontend config).

If verification is rate-limited, re-run only verification: append `--resume` to the same command.

### Seed price history (one time, right after deploy, on a weekday)

Signals need ≥ 50 daily closes. This replays the Chainlink feeds' own historical rounds (mis-scaled launch rounds are filtered on-chain). Run it **before** the keeper records its first close:

```bash
cd contracts && forge script script/SeedHistory.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account goldbench-keeper --broadcast --slow --gas-estimate-multiplier 300
```

Check: `pnpm --filter scripts status` should print `signal: RISK-ON|RISK-OFF …` (SPY/QQQ have ~76 sessions; GLD shows "warming up" until 50 sessions — the engine uses a neutral gold split meanwhile).

## 3. Later: set the project token ($GBEN)

Only after $GBEN exists. Two Timelock transactions by the owner, 48h apart. Addresses come from `deployments/4663.json` (`timelock`, `projectTokenHooks`).

**If the owner is a Safe:** in the Safe Transaction Builder call `Timelock.schedule(target=<HOOKS>, value=0, data=<DATA>, predecessor=0x000…000, salt=0x000…000, delay=172800)`, then after 48h `Timelock.execute(<HOOKS>, 0, <DATA>, 0x000…000, 0x000…000)`, where `<DATA>` is:

```bash
cast calldata "setProjectToken(address)" <GBEN_ADDRESS>
```

**If the owner is a keystore account** (`goldbench-owner`), schedule:

```bash
cast send <TIMELOCK> "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" <HOOKS> 0 $(cast calldata "setProjectToken(address)" <GBEN_ADDRESS>) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 172800 --rpc-url https://rpc.mainnet.chain.robinhood.com --account goldbench-owner
```

…and 48h later execute (anyone may execute):

```bash
cast send <TIMELOCK> "execute(address,uint256,bytes,bytes32,bytes32)" <HOOKS> 0 $(cast calldata "setProjectToken(address)" <GBEN_ADDRESS>) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 --rpc-url https://rpc.mainnet.chain.robinhood.com --account goldbench-owner
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<GBEN_ADDRESS>` on Vercel and redeploy the app. Details: `TOKEN_INTEGRATION.md`.

## 4. Start the keeper

The keeper loop reads chain state with viem and signs every action through `forge script script/Keeper.s.sol` with the `goldbench-keeper` keystore. For unattended operation give Foundry the keystore password in a file only you can read (create it yourself; never commit it):

```bash
KEEPER_PASSWORD_FILE=$HOME/.goldbench/keeper.pass RPC_URL=https://rpc.mainnet.chain.robinhood.com pnpm --filter scripts keeper
```

Every keeper action runs `forge script` with `--gas-estimate-multiplier 300` (override with `GAS_ESTIMATE_MULTIPLIER`). It (a) records daily closes within 8h after each US close, (b) starts a rebalance per vault once the 7-day interval has passed (after 10:00 New York), and (c) executes the 4 TWAP chunks 30 min apart. Run it under a supervisor (pm2/systemd/NSSM). Cron-only alternative for recording: `pnpm --filter scripts record` every 10 min between 16:05 and 23:55 New York on weekdays. Status at any time: `pnpm --filter scripts status`.

Use a dedicated RPC (e.g. Alchemy, the chain's recommended provider) for the keeper — the public endpoint is rate-limited (Cloudflare challenges were observed during testing).

## 5. Deploy the frontend to Vercel

1. Import the repo in Vercel → **Root Directory: `app`**, framework Next.js, install `pnpm install`, build `pnpm build`.
2. Environment variables:
   - `NEXT_PUBLIC_DEPLOYMENT=4663` (reads `app/src/config/deployments.4663.json` written in step 2 — commit it)
   - `NEXT_PUBLIC_RPC_URL=<your RPC>`
   - `NEXT_PUBLIC_WC_PROJECT_ID=<WalletConnect project id>` (optional; injected wallets work without)
   - `NEXT_PUBLIC_PROJECT_TOKEN=` (empty until §3 is done)
   - `NEXT_PUBLIC_GEOBLOCK_COUNTRIES=US,CA,GB,CH` (Stock Tokens may not be offered to U.S. persons and are restricted in CA/GB/CH — get legal advice for your list)
3. Deploy.

## Yearly maintenance
Add next year's NYSE holidays/early closes through the Timelock (`MarketClock.setHolidays(uint256[],true)`, `setEarlyClose(day,780)`; day = days since 1970-01-01 in New York). The guardian can add unscheduled closures instantly with `emergencyClose(day)`.

---

## Proof runs (how this repo was validated)

Local anvil fork of mainnet (uses anvil's unlocked dev accounts — no keys involved):

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 38545 --hardfork cancun
```

```bash
cd contracts && GOLDBENCH_KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 GOLDBENCH_DEPLOYMENT_TAG=fork forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:38545 --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast --slow
```

```bash
cd contracts && GOLDBENCH_DEPLOYMENT=../deployments/4663-fork.json forge script script/SeedHistory.s.sol --rpc-url http://127.0.0.1:38545 --unlocked --sender 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --broadcast --slow
```

```bash
RPC_URL=http://127.0.0.1:38545 GOLDBENCH_DEPLOYMENT=../deployments/4663-fork.json pnpm --filter scripts exec tsx src/fork-demo.ts
```

```bash
NEXT_PUBLIC_RPC_URL=http://127.0.0.1:38545 NEXT_PUBLIC_DEPLOYMENT=4663-fork pnpm --filter app dev
```

Mainnet dry run (simulation only — no `--broadcast`, nothing is sent; writes `deployments/4663.dryrun.json`):

```bash
cd contracts && GOLDBENCH_KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

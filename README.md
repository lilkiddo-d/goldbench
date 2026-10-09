# Goldbench

Risk-rotation vaults on Robinhood Chain (chainId 4663). Three ERC-4626 vaults take USDG deposits and rotate between a tokenized-stock basket (risk-on) and tokenized gold + T-bills (risk-off), driven by an on-chain trend + volatility signal.

| Vault | Max stocks | Contract |
|---|---|---|
| **Steady** | 40% | `RotationVault` clone, `stockCapBps = 4000` |
| **Balanced** | 70% | `stockCapBps = 7000` |
| **Bold** | 100% | `stockCapBps = 10000` (3% USDG cash buffer always kept) |

**Assets (all real, verified on-chain; see [`docs/ASSETS.md`](docs/ASSETS.md))**: base USDG (Paxos), risk-on SPY 60% / QQQ 40%, risk-off GLD (SPDR Gold Trust) and SGOV (0–3M Treasuries). All non-USDG holdings are Stock Tokens issued by Robinhood Assets (Jersey) Limited. No PAXG/XAUT or tokenized T-bill fund exists on the chain yet; the adapters are swappable.

## How it works
1. **PriceHistory** stores one close per US session per asset in 256-slot ring buffers, read from Chainlink through the **OracleAdapter** (staleness, issuer pause flag, optional sequencer feed). Each close is clamped to ±15% of the previous one.
2. **SignalEngine** computes, for the basket and gold, the median-of-3 spot, 50/200-day moving averages and 20-day realised vol.
   - Risk-on when the basket is above its 200-day MA (with a 1% hysteresis band).
   - Exposure is scaled down by volatility (target 15%) and halved in a weak trend (50-day below 200-day).
   - In risk-off, the gold trend splits the defensive sleeve between gold and T-bills.
   - Every parameter is Timelock-controlled within hard bounds.
3. **Allocator** turns the signal and each vault's cap into target weights (fuzz-proven ≤ cap).
4. **RotationVault** rebalances at most weekly, only in US regular hours (**MarketClock**), in 4 TWAP chunks through **DexAdapter** (Uniswap v3). It uses oracle-based min-out (1% max slippage) and deadlines. `RebalanceStarted` emits every signal value that caused the rebalance.
5. Fees: 0.75%/yr management fee only, hard-capped in code, collected by **FeeCollector**. Once $GBEN exists, 50% is rebated to stakers via **ProjectTokenHooks**, which also runs bounded parameter votes through the 48h **Timelock**.
6. **ComplianceRegistry** allowlist hook (off by default) and an optional frontend geoblock.

## Repo
```
contracts/  Foundry: src/ (11 contracts + ComplianceRegistry), test/ (unit, fuzz, invariant, fork), script/ (Deploy, SeedHistory, Keeper)
app/        Next.js + wagmi/viem + RainbowKit frontend (vault cards, signal chart, deposit/withdraw, history, /risk, /stake)
scripts/    keeper loop, daily price recorder, history seeding, status, local fork demo
config/     chains.ts: every address with its source link
docs/       ASSETS.md (issuers, redemption, gaps), SLITHER.md (triage)
deployments/ <chainId>.json written by Deploy.s.sol
```

## Quick start
```bash
pnpm install
```
```bash
cd contracts && forge test --no-match-path "test/fork/*"
```
```bash
cd contracts && forge test --match-path "test/fork/*" -vv
```
```bash
pnpm --filter app dev
```

## Status
- 109 unit/fuzz tests and 4 invariants pass; 100% line coverage on every contract. 4 fork tests run against live mainnet (deploy, seed, deposit, real Uniswap rebalance, redeem).
- Slither: 0 high/medium findings ([`docs/SLITHER.md`](docs/SLITHER.md)).
- Mainnet dry run of `Deploy.s.sol` passes (~27M gas, ~0.001 ETH).

## Docs
[DEPLOY.md](DEPLOY.md) (exact commands) · [DECISIONS.md](DECISIONS.md) · [THREAT_MODEL.md](THREAT_MODEL.md) · [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md)

## Disclaimer
Experimental software, unaudited. Stock Tokens are tokenised debt securities with no rights in the underlying assets. They may not be offered to U.S. persons and are restricted in other jurisdictions. Not investment advice.

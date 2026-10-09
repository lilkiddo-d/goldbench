# DECISIONS

One line of reasoning per decision. Newest considerations at the bottom of each section.

## Assets & chain
- **Base asset = USDG (Paxos Global Dollar, 6 dec).** It is the only stablecoin on the official Robinhood Chain token list; a USDC/USD feed exists but no canonical USDC token is listed.
- **Risk-on basket = SPY 60% / QQQ 40% Stock Tokens.** Broad ETFs with Chainlink feeds and the deepest USDG pools; VTI has no feed, single stocks add idiosyncratic risk.
- **Gold = GLD Stock Token.** No PAXG/XAUT deployment or feed exists on the chain (verified in the official token list and Chainlink directory); GLD is the only gold exposure with a feed.
- **T-bills = SGOV Stock Token (0–3M Treasury ETF).** No native tokenized T-bill fund (BUIDL/USTB/etc.) exists on the chain; SHY/BND have no feeds and carry duration.
- **SLV/USO not used.** Silver adds a second commodity with no trend model; USO suffers futures roll drag.
- **Addresses come only from official sources** (Robinhood docs + `api.robinhood.com/rhj/assets`, Chainlink reference-data JSON, Uniswap deployment docs) and were re-checked on-chain; listed with sources in `config/chains.ts` and `contracts/script/Addresses.sol`.
- **Execution venue = Uniswap v3 SwapRouter02**, fee tiers chosen per asset by deepest USDG pool on 2026-10-08 (SPY 0.05%, QQQ 0.05%, GLD 0.3%, SGOV 0.3%). Rialto/RFQ venues have no published contract interfaces; DexAdapter is swappable.
- **No sequencer uptime feed** — Chainlink publishes none for Robinhood Chain; OracleAdapter supports one (address(0) = off) so it can be enabled the day it appears.

## Signal engine
- **Spot = median of last 3 daily closes; stored closes clamped to ±15%/day vs previous close.** Two independent layers so one bad print can neither flip the regime nor poison the MAs quickly (fuzz-tested).
- **Hysteresis band (1%) around the 200-day MA.** Prevents whipsaw rebalances when price hugs the MA.
- **Vol targeting: scale = clamp(15% / realised 20d vol, 25%, 100%).** "Scaled down by volatility" with a floor so a vol spike doesn't force a full exit on its own.
- **Weak trend (50d < 200d while spot > 200d) deploys 50% of the cap.** Uses the 50-day MA the spec asks for without adding a second regime.
- **Gold trend steers only the split of the risk-off sleeve** (60% gold if gold > its MA, else 20%); T-bills take the rest.
- **Warm-up: MA_long uses all available closes once ≥ 50 exist.** Feeds only began in June 2026 (~76 sessions), so a strict 200-day requirement would block signals until 2027.
- **Gold leg degrades to a neutral 40% split while GLD history < 50 sessions** instead of blocking the engine — the GLD feed only started 2026-09-19.
- **Seeding replays the oracle's own historical rounds** (keeper chooses round ids, prices are re-read on-chain) rather than accepting admin-supplied prices.
- **Seed sanity band (3× of live price).** Real finding: the first 7 SPY and 12+ QQQ rounds (2026-06-22/23) report prices ~1e8× too large; without the band the series anchored to garbage.
- **`resetSeries` is Timelock-only.** Recovery tool for a poisoned series; the 48h delay prevents using it to time a rebalance.
- **Parameters are an indexed array with hard-coded bounds + cross-checks** (`maShort < maLong`, `minHistory` between vol window and maLong) so both the Timelock and staker votes go through one validator.

## Vaults
- **Vaults are EIP-1167 clones of one implementation** (OZ upgradeable base, initializer locked on the implementation). Keeps VaultFactory far below 24KB; clones are *not* upgradeable.
- **12-decimal shares (`_decimalsOffset = 6`).** Virtual shares neutralise the first-depositor inflation/donation attack.
- **Strict valuation on every state change, lenient for views.** Deposits/withdrawals/rebalances revert on stale oracles, a >10% move vs last close, or a >3% USDG depeg; `totalAssets()` falls back to last closes so UIs never break.
- **Cash withdrawals limited to idle USDG; `redeemInKind` always available (even paused).** Avoids forced selling into thin pools and guarantees exit.
- **3% USDG cash buffer** kept for withdrawals.
- **Rebalance = weekly minimum interval (hard floor 7 days), 4 chunks × 30 min, only in US regular session.** Spec requirement; keeper starts ≥ 10:00 New York to skip the opening auction.
- **Min-out from oracle price with 1% max slippage; failed swaps are caught and logged, not fatal.** One illiquid pool can't block the whole rebalance.
- **Stock cap enforced at trade time with a slippage haircut + same-chunk trim.** Real fork run showed a favourable SPY fill pushing Steady to 40.01%; now provably ≤ cap.
- **Management fee 0.75%/yr minted as shares, hard cap `MAX_MGMT_FEE_BPS = 75`** (can be lowered, never raised). No performance fee exists in code.
- **Default deposit cap 250,000 USDG per vault** — sized to current on-chain liquidity (~$200k in the SPY/USDG pool).
- **Exits to self are never compliance-gated**; deposits, share transfers and third-party receivers are.

## Governance & ops
- **48h Timelock (hard floor in code) holds DEFAULT_ADMIN_ROLE everywhere; deployer renounces in the same script and the script asserts it.**
- **Guardian can pause and declare emergency market closures only; unpausing needs the Timelock.** Fast defence, slow recovery.
- **Executor role open (address(0))** — anyone can execute a matured operation, so a stuck owner can't block a passed vote.
- **ProjectTokenHooks gets PROPOSER_ROLE at deploy.** Inert until the token is set (all token paths revert `TokenNotSet`); saves a 48h round trip later. Only it gets proposer, not canceller.
- **Keeper actions are Foundry scripts signed with the `goldbench-keeper` keystore**; the TS loop only reads chain state and decides timing. Also needed because Windows Application Control blocked `cast.exe` on the build machine.
- **NYSE holidays/early closes for 2026–2027 loaded at deploy**; the Timelock must add each new year (documented in DEPLOY.md).
- **Swaps refuse to start with < 400k gas left (`MIN_SWAP_GAS`), reverting the whole chunk.** Found on the fork: `eth_estimateGas` under-estimates try/catch swaps (63/64 rule); a caught out-of-gas would silently skip a trade and burn a TWAP chunk. Keeper txs also use a 3x gas-estimate multiplier.
- **Local fork runs use `anvil --hardfork cancun`.** Prague-mode anvil reads the EIP-2935 blockhash contract every block, which fails once the non-archive public RPC prunes the fork block; contracts target Cancun anyway.
- **Fork tests fork the latest block** (public RPC is not an archive node); outside market hours they warp to the next session and re-publish the feeds' *current* answers with fresh timestamps.

## Token ($GBEN)
- **No ERC-20 is written or deployed.** `setProjectToken` is one-shot and admin-only; a MockERC20 exists only under `contracts/test/`.
- **Rebate = 50% of fee shares to stakers pro-rata to stake** (MasterChef accumulator, paid in vault shares). Pro-rata-to-vault-holdings would need hooks in every share transfer; documented as a possible v2.
- **Votes lock the voter's stake until the vote ends**, preventing double-voting by moving tokens between accounts; quorum = 10% of stake at proposal time.

## Compliance & frontend
- **ComplianceRegistry ships disabled** (spec) but deploy wires it into every vault so enabling is one Timelock call.
- **Suggested geoblock US, CA, GB, CH** — Stock Tokens may not be offered to U.S. persons and are restricted in those jurisdictions per the issuer.
- **No Robinhood name or logo in branding**; the chain is named only in technical contexts.

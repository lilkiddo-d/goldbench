# Goldbench Threat Model

Scope: `contracts/src/**` deployed on Robinhood Chain (4663), the keeper (`scripts/`), and the frontend (`app/`).

## Assets at risk
User USDG and the Stock Tokens (SPY, QQQ, GLD, SGOV) held by the three vaults; share price integrity; governance control.

## Actors & trust
| Actor | Powers | Trust |
|---|---|---|
| Timelock (48h, owner multisig proposes/cancels) | DEFAULT_ADMIN on every contract: params within hard bounds, swap modules (oracle, DEX, compliance), fees ≤ 0.75% | Trusted, delayed: users get 48h to exit via `redeemInKind` |
| Guardian | Pause; emergency market closure; cancel a rebalance plan | Semi-trusted: can only *stop* things |
| Keeper (`goldbench-keeper`) | Record daily closes (oracle prices only), seed from oracle rounds (once), start rebalance (≥ 7 days apart, market hours), execute chunks | Untrusted for prices (all prices come from Chainlink); can only choose *timing* within on-chain windows |
| $GBEN stakers | Propose/vote SignalEngine params within hard bounds → scheduled on Timelock | Delayed 48h, owner can cancel |
| Anyone | Deposit/withdraw, execute matured Timelock ops, `accrueFees`, `FeeCollector.distribute` | Untrusted |

## Top risks (spec-mandated)

### 1. Signal manipulation via a single bad price
*Threat:* one wrong oracle print (bug, mis-scaling, manipulation of a thin "dex_state_price" feed like GLD) flips risk-on/off and triggers a damaging rotation.
*Mitigations:*
- Spot used by the signal = **median of the last 3 daily closes** → one outlier is ignored entirely (`testFuzz_singleOutlierCannotFlipRegime`, 2×–1000× up/down).
- Every stored close is **clamped to ±15%** of the previous close → an outlier moves a 200-day MA by ≤ 0.075%.
- **1% hysteresis band** around the MA.
- Only **one close per session**, recorded within 8h after the close; keeper cannot inject prices.
- **Seeding replays signed oracle rounds** and **rejects rounds outside 3× of the live price**. This is not theoretical: the first SPY/QQQ rounds on this chain (2026-06-22/23) are ~1e8× too large; a fork test reproduces and proves the filter.
- Vault NAV for entries/exits rejects oracle prices **> 10% from the last close** and **USDG outside ±3%**.
- Residual: a *sustained* (≥ 2 consecutive sessions) wrong feed will move the median. Guardian can pause; Timelock can `resetSeries`. A poisoned first print recovers only 15%/day → `resetSeries` exists for that.

### 2. Rebalance front-running / sandwiching
*Threat:* rebalances are predictable (public signal, weekly cadence) and pools are thin (~$0.2–1.3M).
*Mitigations:*
- **TWAP: 4 chunks × 30 min**, each trading 1/remaining of the gap; per-vault **deposit cap 250k USDG** keeps chunk size small vs pool depth.
- Every swap has **min-out = oracle value × (1 − 1%)** and a **deadline**; adapter re-checks the recipient's balance delta.
- Robinhood Chain uses **first-come-first-served sequencing** (no priority-fee reordering), making classic sandwiches much harder.
- A failing swap is **skipped, not retried at a worse price** within the chunk.
- Only the keeper can trigger rebalances, only in US regular hours (when the oracle and the off-chain market are both live, so pool–oracle arbitrage is tight).
- Residual: a searcher can pre-position before a known regime change; worst case per chunk is bounded by 1% slippage. Measured on fork: fills within 0.4% of oracle for $100.

### 3. Gold-issuer (and stock-token issuer) risk
*Threat:* all non-USDG holdings are Stock Tokens issued by **Robinhood Assets (Jersey) Limited** — tokenised *debt securities* giving economic exposure but **no legal or beneficial rights** in the underlying shares or gold. The GLD token tracks SPDR Gold Trust (bullion custodied by HSBC for World Gold Trust Services); token holders cannot redeem for gold. Primary mint/burn is limited to Authorised Participants (BBVI at issuance) during the tokenization window.
*Mitigations:*
- Risk documented per asset (`docs/ASSETS.md`) and in the app's `/risk` page.
- Oracle adapter honours the issuer's `oraclePaused()` flag (corporate actions) → strict paths revert, rebalances pause.
- Prices include the `uiMultiplier` (dividends/splits) per issuer docs; we never apply it twice.
- Swappable OracleAdapter/DexAdapter and an append-only asset list allow migrating the gold sleeve to a bullion-backed token (e.g. PAXG) if one is bridged with a feed.
- Residual (accepted, disclosed): issuer insolvency, de-tokenisation, transfer restrictions or sanctions on the vault address. `redeemInKind` returns the tokens themselves.

## Other risks
| Risk | Mitigation |
|---|---|
| Reentrancy (malicious token/venue) | `nonReentrant` on every external entry; CEI ordering (plan state committed before swaps; shares burned before in-kind transfers); tested with a re-entering router |
| Share inflation / donation attack | `_decimalsOffset = 6` virtual shares |
| Deposit dilution via stale NAV (weekends, oracle pause) | Strict valuation reverts on stale/deviating prices; invariant `invariant_depositsNeverDilute` |
| Stock cap breach | Allocator targets ≤ cap (fuzz); buys clipped to cap × (1 − slippage); same-chunk trim; invariant `invariant_stockCapNeverExceededByTrading` |
| Oracle staleness / L2 sequencer outage | Per-feed max staleness (30h); optional sequencer feed + grace period (none published yet) |
| Liquidity crunch on exit | 3% cash buffer; `redeemInKind` always available, even when paused |
| Fee abuse | Management fee capped at 0.75%/yr in code; no performance fee path exists |
| Governance takeover | 48h floor on the delay, owner multisig cancels, hard bounds on every parameter, `setProjectToken` one-shot |
| Unbounded loops / gas DoS | Max 8 assets in history, 8 holdings per vault, 4 basket assets, 8 vaults in hooks, batch limits (32 holidays, 64 seed rounds, 200 allowlist entries) |
| Gas griefing / under-estimated keeper tx | `_swap` reverts the chunk if `gasleft() < 400k`, so a starved tx can never silently skip trades; keeper uses a 3x gas multiplier |
| Keeper key compromise | Keeper cannot set prices or params; worst case: mistimed (still weekly-limited, market-hours-only, slippage-bounded) rebalances or skipped recordings. Rotate via Timelock role grant/revoke |
| Market-calendar drift | Holidays loaded for 2026–2027; Timelock must add each year; guardian can add emergency closures |
| Compliance | Stock Tokens may not be offered to U.S. persons; ComplianceRegistry (disabled by default) + frontend geoblock (suggested US, CA, GB, CH) |

## Static analysis
Slither run on `contracts/src` — results and triage in `docs/SLITHER.md`. All high/medium findings were fixed or triaged as false positives with justification.

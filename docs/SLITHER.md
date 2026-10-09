# Slither results

Command (from `contracts/`): `python -m slither . --config-file slither.config.json` (Slither 0.11.6, solc 0.8.28; `test/`, `script/`, dependencies excluded; naming/pragma/solc-version/assembly style detectors disabled in the config).

## High / Medium: **0**

```
python -m slither . --config-file slither.config.json --exclude-low --exclude-informational --exclude-optimization
INFO:Slither:. analyzed (62 contracts with 59 detectors), 0 result(s) found
```

### What was found on the first run and how it was resolved
| Detector (impact) | Where | Resolution |
|---|---|---|
| reentrancy-balance (Med) | `UniswapV3DexAdapter.swapExactIn` balance delta around router call | **Fixed:** use the router's returned amount (min-out is enforced by the router and re-checked); no balance read across the call. |
| divide-before-multiply (Med) | `PriceHistory.volatility`, `RotationVault._sellLeg` | **Fixed:** single division at the end (`sqrt(ss*252/(n-1))`; `mulDiv(gap, BPS-slip, BPS*remaining)`). |
| divide-before-multiply (Med) | `MarketClock.daysFromCivil/civilFromDays` | **Annotated:** truncating integer division *is* the calendar algorithm (fuzz-tested round trip). |
| uninitialized-local (Med) | accumulators in Allocator/PriceHistory/SignalEngine/FeeCollector/RotationVault | **Fixed:** explicit `= 0` initialisation. |
| reentrancy-no-eth (Med) | `RotationVault.startRebalance` writes targets after `engine.refreshSignal()` | **Annotated:** calls go only to Timelock-set protocol modules, function is `nonReentrant`, plan state is committed before the calls; targets must be written from the call results. |
| incorrect-equality (Med) | `== 0` checks on balances/NAV/fee shares | **Annotated:** zero-guards only (skip/no-op), never used for accounting or access decisions. |
| unused-return (Med) | ignoring Chainlink `roundId/startedAt/answeredInRound`, `updatedAt` from the adapter, basket weights | **Annotated:** fields are deprecated or validated elsewhere (staleness enforced inside the adapter). |

Note: decorative UTF-8 characters in comments shifted Slither's byte→line mapping, so line-anchored annotations initially missed; sources are now pure ASCII.

## Low / Informational (108, accepted)
| Detector | Count | Why accepted |
|---|---|---|
| calls-loop | 91 | Loops are hard-bounded (≤ 8 assets/holdings/vaults, ≤ 64 seed rounds, ≤ 256 closes) over trusted protocol modules / ERC-20s; per-asset oracle failures in `recordDailyCloses` are caught so one asset cannot block others. |
| timestamp | 12 | Time windows (market hours, staleness, weekly interval, voting periods) are inherently timestamp-based; granularity is minutes–days, far above sequencer timestamp drift. |
| missing-inheritance | 2 | Concrete contracts expose interface functions without inheriting secondary interfaces (style). |
| unindexed-event-address | 2 | Event signature choice; indexing not needed by consumers. |
| cyclomatic-complexity | 1 | `SignalEngine.bounds` lookup table — linear and fully tested. |

Full output of the last run: `slither.txt` (repo root).

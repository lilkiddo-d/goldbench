# $GBEN Token Integration

**This repository does not contain, compile into production, or deploy any ERC-20 for the project.** $GBEN will be launched separately on a launchpad. Goldbench only *consumes* it, through one contract: `ProjectTokenHooks`. A `MockERC20` exists solely under `contracts/test/` for tests.

## Lifecycle

| State | What works |
|---|---|
| **Before `setProjectToken`** (as deployed) | Entire protocol: deposits, withdrawals, rebalances, fees. 100% of management fees go to the treasury. `stake`, `unstake`, `propose`, `vote`, `queue` revert with `TokenNotSet()`. Frontend hides all token UI. |
| **After `setProjectToken(gben)`** | Staking, fee rebates to stakers, staker votes on signal parameters. |

`setProjectToken(address)` is callable **exactly once** (`TokenAlreadySet()` afterwards), only by `DEFAULT_ADMIN_ROLE` — which after deployment is the **48h Timelock**. So it is a two-step owner action: schedule, wait 48h, execute (commands in `DEPLOY.md` §3).

## Feature 1 — management-fee rebate for stakers
1. Vaults mint the 0.75%/yr management fee as vault shares to `FeeCollector`.
2. Anyone calls `FeeCollector.distribute(vault)`. If the token is set and `totalStaked > 0`, `rebateBps` (default **50%**, Timelock-adjustable 0–100%) of the fee shares go to `ProjectTokenHooks`, the rest to the treasury.
3. `ProjectTokenHooks.notifyRebate` updates a per-vault accumulator; each staker earns pro-rata to their stake (`claimable(vault, user)`), claimed with `claimRebate(vault)` and paid **in vault shares** (redeemable like any other share).
4. Stakers who join later earn only from later rebates (debt accounting). Unstaking is allowed while the contract is paused so users can always exit — except during an open vote they cast (see below).

## Feature 2 — staker votes on signal parameters
- `propose(paramId, value)` — requires `staked ≥ proposalThreshold` (default 1 GBEN; Timelock-adjustable). The value is validated **up front** against `SignalEngine.validateParam` (hard bounds + consistency), so out-of-bounds proposals cannot even be created.
- `vote(id, support)` — weight = current stake; each address votes once; the voter's stake is **locked until the vote ends** (prevents voting, moving tokens, voting again).
- `queue(id)` — after the voting period (default 3 days), if `for > against` and `for ≥ quorum` (default 10% of stake at proposal time), it **schedules** `SignalEngine.setParam(id, value)` on the Timelock (hooks holds `PROPOSER_ROLE`, granted at deploy, inert until the token is set).
- After **48h** anyone executes it on the Timelock; `setParam` re-checks bounds at execution. The owner multisig (canceller) can veto during the delay.

| id | Parameter | Default | Hard bounds |
|---|---|---|---|
| 0 | Long MA (days) | 200 | 100–250 |
| 1 | Short MA (days) | 50 | 10–100 (< long) |
| 2 | Volatility window | 20 | 10–60 |
| 3 | Target vol (bps) | 1500 | 500–4000 |
| 4 | Min vol scale (bps) | 2500 | 0–10000 |
| 5 | Hysteresis (bps) | 100 | 0–500 |
| 6 | Weak-trend scale (bps) | 5000 | 0–10000 |
| 7 | Gold share, gold uptrend (bps) | 6000 | 0–10000 |
| 8 | Gold share, gold downtrend (bps) | 2000 | 0–10000 |
| 9 | Min history (sessions) | 50 | 30–250 (> vol window, ≥ short MA, ≤ long MA) |

Stakers **cannot** touch vault caps, fees, oracles, DEX adapters, compliance, or anything outside this table.

## Frontend
`NEXT_PUBLIC_PROJECT_TOKEN` — empty (default) hides every token feature (no Stake page, no rebate or governance UI). Set it to the $GBEN address after the on-chain `setProjectToken` has executed, then redeploy the app.

## Checklist when $GBEN launches
1. Confirm the launchpad token is a plain ERC-20 (no fee-on-transfer/rebasing — staking accounting assumes exact transfers).
2. Owner multisig schedules + executes `setProjectToken` via the Timelock (`DEPLOY.md` §3).
3. Optionally tune `setGovernanceParams(threshold, period, quorumBps)` and `FeeCollector.setRebateBps` (Timelock).
4. Set `NEXT_PUBLIC_PROJECT_TOKEN` on Vercel and redeploy.

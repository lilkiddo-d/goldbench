/**
 * Goldbench keeper loop.
 *   - after each US session close: record daily closes (PriceHistory.recordDailyCloses)
 *   - during US market hours: start a rebalance when the weekly interval has elapsed, then execute TWAP chunks
 * Every on-chain action is signed by Foundry using the `goldbench-keeper` keystore (never a raw key) and every
 * action re-checks its preconditions on-chain, so a stale decision here simply fails in simulation.
 *
 *   KEEPER_PASSWORD_FILE=~/.goldbench/keeper.pass pnpm --filter scripts keeper
 */
import type { Address } from "viem";
import { abi, client, env, forgeKeeper, loadDeployment, log, nowTs } from "./lib.js";
import { recordIfDue } from "./record.js";

const VAULT_KEYS = ["vaultSteady", "vaultBalanced", "vaultBold"] as const;

async function nyMinuteOfDay(now: bigint, clock: Address): Promise<number> {
  // closeTimestamp(day) is 16:00 New York (or an early close); derive local minute from it
  const day = await client.readContract({ address: clock, abi: abi.clock, functionName: "etDay", args: [now] });
  const close = await client.readContract({ address: clock, abi: abi.clock, functionName: "closeTimestamp", args: [day] });
  const minutesToClose = Number((close - now) / 60n);
  return 16 * 60 - minutesToClose;
}

async function tickVaults(): Promise<void> {
  const d = loadDeployment();
  const clock = d.marketClock as Address;
  const now = await nowTs();
  const open = await client.readContract({ address: clock, abi: abi.clock, functionName: "isOpen", args: [now] });
  if (!open) return;

  let signalReady = true;
  try {
    const s = await client.readContract({ address: d.signalEngine as Address, abi: abi.engine, functionName: "computeSignal" });
    log(`signal riskOn=${s.riskOn} ratio=${Number(s.basketRatioLong) / 1e18} scale=${s.stockScaleBps}bps days=${s.historyDays}`);
  } catch (e) {
    signalReady = false;
    log("signal not ready:", (e as Error).message.split("\n")[0]);
  }

  for (const key of VAULT_KEYS) {
    const vault = d[key] as Address;
    const [plan, paused, chunkInterval, interval, lastStart] = await Promise.all([
      client.readContract({ address: vault, abi: abi.vault, functionName: "plan" }),
      client.readContract({ address: vault, abi: abi.vault, functionName: "paused" }),
      client.readContract({ address: vault, abi: abi.vault, functionName: "chunkInterval" }),
      client.readContract({ address: vault, abi: abi.vault, functionName: "rebalanceInterval" }),
      client.readContract({ address: vault, abi: abi.vault, functionName: "lastRebalanceStart" }),
    ]);
    if (paused) continue;
    const [active, , , lastChunkAt, expiresAt] = plan;
    if (active && now <= expiresAt) {
      if (lastChunkAt === 0n || now >= lastChunkAt + BigInt(chunkInterval)) await forgeKeeper("chunk(address)", [vault]);
      continue;
    }
    const due = lastStart === 0n || now >= lastStart + BigInt(interval);
    if (due && signalReady && (await nyMinuteOfDay(now, clock)) >= env.rebalanceAfterMinute) {
      // leave room for all chunks before the close: chunkInterval × 4 by default
      await forgeKeeper("start(address)", [vault]);
    }
  }
}

async function main() {
  log(`keeper up — rpc ${env.rpcUrl}, deployment ${env.deploymentFile}, poll ${env.pollSeconds}s`);
  if (!env.signerArgs && !env.passwordFile) {
    log("WARNING: KEEPER_PASSWORD_FILE not set — forge will prompt for the keystore password on every action");
  }
  for (;;) {
    try {
      await recordIfDue();
      await tickVaults();
    } catch (e) {
      log("tick error:", (e as Error).message.split("\n")[0]);
    }
    await new Promise((r) => setTimeout(r, env.pollSeconds * 1000));
  }
}

main();

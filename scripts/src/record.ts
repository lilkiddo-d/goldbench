/** Shared "record today's closes if due" logic (used by the keeper loop and the record CLI). */
import { abi, client, forgeKeeper, loadDeployment, log, nowTs } from "./lib.js";
import type { Address } from "viem";

export async function recordIfDue(): Promise<boolean> {
  const d = loadDeployment();
  const clock = d.marketClock as Address;
  const history = d.priceHistory as Address;
  const now = await nowTs();

  const [day, delay, assets, paused] = await Promise.all([
    client.readContract({ address: clock, abi: abi.clock, functionName: "lastCompletedSession", args: [now] }),
    client.readContract({ address: history, abi: abi.history, functionName: "maxRecordDelay" }),
    client.readContract({ address: history, abi: abi.history, functionName: "assets" }),
    client.readContract({ address: history, abi: abi.history, functionName: "paused" }),
  ]);
  if (paused) {
    log("PriceHistory paused — skip");
    return false;
  }
  const closeTs = await client.readContract({ address: clock, abi: abi.clock, functionName: "closeTimestamp", args: [day] });
  if (now > closeTs + BigInt(delay)) {
    log(`record window for session ${day} closed`);
    return false;
  }
  const lastDays = await Promise.all(
    assets.map((a) => client.readContract({ address: history, abi: abi.history, functionName: "lastDay", args: [a] })),
  );
  if (lastDays.every((x) => x >= day)) {
    log(`session ${day} already recorded`);
    return false;
  }
  const code = await forgeKeeper("record()");
  log(code === 0 ? `recorded session ${day}` : `record failed (exit ${code})`);
  return code === 0;
}


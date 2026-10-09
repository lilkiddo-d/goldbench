/** Read-only status dump: signal, history depth, vault NAVs and plans. `pnpm --filter scripts status` */
import { formatUnits, type Address } from "viem";
import { abi, client, loadDeployment, nowTs } from "./lib.js";

const d = loadDeployment();
const now = await nowTs();
const open = await client.readContract({ address: d.marketClock as Address, abi: abi.clock, functionName: "isOpen", args: [now] });
console.log(`block time ${new Date(Number(now) * 1000).toISOString()}  US market ${open ? "OPEN" : "closed"}`);

const assets = await client.readContract({ address: d.priceHistory as Address, abi: abi.history, functionName: "assets" });
for (const a of assets) {
  const [count, closed] = await Promise.all([
    client.readContract({ address: d.priceHistory as Address, abi: abi.history, functionName: "count", args: [a] }),
    client.readContract({ address: d.priceHistory as Address, abi: abi.history, functionName: "seedingClosed", args: [a] }),
  ]);
  console.log(`history ${a}: ${count} closes${closed ? "" : " (seeding open)"}`);
}
try {
  const s = await client.readContract({ address: d.signalEngine as Address, abi: abi.engine, functionName: "computeSignal" });
  console.log(
    `signal: ${s.riskOn ? "RISK-ON" : "RISK-OFF"}  basket/MA=${(Number(s.basketRatioLong) / 1e18).toFixed(4)}  ` +
      `vol=${Number(s.basketVolBps) / 100}%  stockScale=${Number(s.stockScaleBps) / 100}%  goldShare=${Number(s.goldShareBps) / 100}%`,
  );
} catch (e) {
  console.log("signal: not ready —", (e as Error).message.split("\n")[0]);
}
for (const k of ["vaultSteady", "vaultBalanced", "vaultBold"]) {
  const v = d[k] as Address;
  const [name, ta, w, plan] = await Promise.all([
    client.readContract({ address: v, abi: abi.vault, functionName: "name" }),
    client.readContract({ address: v, abi: abi.vault, functionName: "totalAssets" }),
    client.readContract({ address: v, abi: abi.vault, functionName: "stockWeightBps" }),
    client.readContract({ address: v, abi: abi.vault, functionName: "plan" }),
  ]);
  console.log(`${name}: NAV ${formatUnits(ta, 6)} USDG, stocks ${Number(w) / 100}%, plan ${plan[0] ? `active ${plan[1]}/${plan[2]}` : "idle"}`);
}

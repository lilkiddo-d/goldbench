"use client";

import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { rotationVaultAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero } from "@/config/deployments";
import { fmtDateTime, fmtDuration } from "@/lib/format";
import { Pill } from "./Badges";
import { Card, Row } from "./ui";

export function PlanStatus({ vault }: { vault: Address }) {
  const enabled = !deployment.placeholder && !isZero(vault);
  const c = { address: vault, abi: rotationVaultAbi, chainId: robinhoodChain.id } as const;
  const q = useReadContracts({
    allowFailure: true,
    contracts: [
      { ...c, functionName: "plan" },
      { ...c, functionName: "rebalanceId" },
      { ...c, functionName: "lastRebalanceStart" },
      { ...c, functionName: "rebalanceInterval" },
    ],
    query: { enabled, refetchInterval: 30_000 },
  });
  const d = q.data ?? [];
  const plan = d[0]?.result as readonly [boolean, number, number, bigint, bigint] | undefined;
  const id = d[1]?.result as bigint | undefined;
  const last = d[2]?.result as bigint | undefined;
  const interval = d[3]?.result as number | undefined;
  const now = Math.floor(Date.now() / 1000);
  const next = last !== undefined && interval !== undefined && last > 0n ? Number(last) + interval : undefined;
  const active = plan?.[0] && Number(plan[4]) > now;

  return (
    <Card
      title="Rebalance plan"
      right={plan ? active ? <Pill tone="up">In progress</Pill> : <Pill tone="neutral">Idle</Pill> : undefined}
    >
      <div className="divide-y divide-ink-800">
        <Row label="Rebalance #" value={id !== undefined ? id.toString() : "—"} />
        <Row label="Chunks" value={plan ? `${plan[1]} / ${plan[2]}` : "—"} />
        <Row label="Last chunk" value={plan ? fmtDateTime(plan[3]) : "—"} />
        <Row label="Plan expires" value={plan && plan[0] ? fmtDateTime(plan[4]) : "—"} />
        <Row label="Last rebalance started" value={last ? fmtDateTime(last) : "never"} />
        <Row
          label="Next eligible"
          value={next ? (next <= now ? "now (next US session)" : `in ${fmtDuration(next - now)}`) : last === 0n ? "any US session" : "—"}
        />
      </div>
      <p className="mt-3 text-xs text-ink-400">
        Rebalances run at most once per interval ({interval ? fmtDuration(interval) : "7d"}), only during US market hours,
        split into chunks to limit slippage on thin pools.
      </p>
    </Card>
  );
}

"use client";

import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";
import type { Address } from "viem";
import { symbolOf, USDG_DECIMALS } from "@/config/deployments";
import { fmtBps, fmtUsd } from "@/lib/format";

export const ASSET_COLORS: Record<string, string> = {
  SPY: "#7aa2f7",
  QQQ: "#a78bfa",
  GLD: "#e8c25e",
  SGOV: "#5eead4",
  USDG: "#8a8373",
};
const fallback = ["#f472b6", "#fb923c", "#38bdf8", "#c084fc"];

type Alloc = readonly [readonly Address[], readonly bigint[], readonly bigint[], bigint, bigint];

export type Slice = { label: string; value: bigint; bps: number; color: string };

export function slicesFromAllocation(a: Alloc | undefined): Slice[] {
  if (!a) return [];
  const [assets, values, , idle, nav] = a;
  const out: Slice[] = assets.map((addr, i) => {
    const label = symbolOf(addr);
    return {
      label,
      value: values[i] ?? 0n,
      bps: nav > 0n ? Number(((values[i] ?? 0n) * 10_000n) / nav) : 0,
      color: ASSET_COLORS[label] ?? fallback[i % fallback.length],
    };
  });
  out.push({ label: "USDG (idle)", value: idle, bps: nav > 0n ? Number((idle * 10_000n) / nav) : 0, color: ASSET_COLORS.USDG });
  return out.filter((s) => s.value > 0n);
}

export function AllocationPie({ allocation, size = 160, legend = true }: { allocation: Alloc | undefined; size?: number; legend?: boolean }) {
  const slices = slicesFromAllocation(allocation);
  const empty = slices.length === 0;
  const data = empty
    ? [{ label: "empty", n: 1, color: "#2a2720", bps: 0, value: 0n }]
    : slices.map((s) => ({ ...s, n: Math.max(s.bps, 1) }));

  return (
    <div className="flex flex-wrap items-center gap-5">
      <div style={{ width: size, height: size }} className="relative shrink-0">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie data={data} dataKey="n" nameKey="label" innerRadius="62%" outerRadius="100%" stroke="#12110e" strokeWidth={2} isAnimationActive={false}>
              {data.map((d) => (
                <Cell key={d.label} fill={d.color} />
              ))}
            </Pie>
            {!empty && (
              <Tooltip
                contentStyle={{ background: "#12110e", border: "1px solid #3a362c", borderRadius: 8, fontSize: 12 }}
                itemStyle={{ color: "#ece6d6" }}
                formatter={(_v, _n, item) => {
                  const p = item.payload as Slice;
                  return [`${fmtBps(p.bps)} · ${fmtUsd(p.value, USDG_DECIMALS)}`, p.label];
                }}
              />
            )}
          </PieChart>
        </ResponsiveContainer>
        {empty && (
          <div className="absolute inset-0 flex items-center justify-center text-center text-xs text-ink-400">No assets yet</div>
        )}
      </div>
      {legend && !empty && (
        <ul className="min-w-[9rem] flex-1 space-y-1.5 text-sm">
          {slices.map((s) => (
            <li key={s.label} className="flex items-center justify-between gap-3">
              <span className="flex items-center gap-2">
                <span className="h-2.5 w-2.5 rounded-sm" style={{ background: s.color }} />
                {s.label}
              </span>
              <span className="font-mono text-ink-300">{fmtBps(s.bps)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

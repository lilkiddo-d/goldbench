"use client";

import { useMemo } from "react";
import { CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { priceHistoryAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero, symbolOf } from "@/config/deployments";
import type { useEngine } from "@/hooks/useProtocol";
import { fmtDay, fmtNumber } from "@/lib/format";
import { Card } from "./ui";

const N = 256n;

type Point = { i: number; day: number; value: number; ma: number | null };

/** Steps back `k` weekdays from `day` (holidays ignored, so dates are approximate). */
function weekdaysBack(day: number, k: number) {
  let d = day;
  let left = k;
  while (left > 0) {
    d -= 1;
    const wd = (d + 4) % 7; // 1970-01-01 was a Thursday → 0=Sun
    if (wd !== 0 && wd !== 6) left--;
  }
  return d;
}

function rollingMa(values: number[], window: number): (number | null)[] {
  const out: (number | null)[] = new Array(values.length).fill(null);
  if (window < 1) return out;
  let sum = 0;
  for (let i = 0; i < values.length; i++) {
    sum += values[i];
    if (i >= window) sum -= values[i - window];
    if (i >= window - 1) out[i] = sum / window;
  }
  return out;
}

function useCloses(assets: readonly Address[]) {
  const ph = deployment.priceHistory;
  const enabled = !deployment.placeholder && !isZero(ph) && assets.length > 0;
  const q = useReadContracts({
    allowFailure: true,
    contracts: assets.flatMap((a) => [
      { address: ph, abi: priceHistoryAbi, functionName: "recentCloses", args: [a, N], chainId: robinhoodChain.id } as const,
      { address: ph, abi: priceHistoryAbi, functionName: "lastDay", args: [a], chainId: robinhoodChain.id } as const,
    ]),
    query: { enabled, refetchInterval: 300_000 },
  });
  const series = useMemo(() => {
    const data = q.data ?? [];
    return assets.map((a, i) => {
      const closes = (data[2 * i]?.result as readonly bigint[] | undefined) ?? [];
      const lastDay = Number((data[2 * i + 1]?.result as bigint | undefined) ?? 0n);
      // newest-first on-chain → oldest-first here
      return { asset: a, closes: [...closes].reverse().map((c) => Number(c) / 1e18), lastDay };
    });
  }, [q.data, assets]);
  return Object.assign(series, { loading: enabled && q.isLoading });
}

function buildSeries(values: number[], lastDay: number, maWindow: number): { points: Point[]; window: number } {
  const L = values.length;
  const w = Math.min(maWindow, L);
  const ma = rollingMa(values, w);
  return {
    window: w,
    points: values.map((v, i) => ({ i, day: lastDay ? weekdaysBack(lastDay, L - 1 - i) : 0, value: v, ma: ma[i] })),
  };
}

function SeriesChart({ points, valueLabel, maLabel, color, digits }: { points: Point[]; valueLabel: string; maLabel: string; color: string; digits: number }) {
  return (
    <div className="h-64 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
          <CartesianGrid stroke="#2a2720" strokeDasharray="3 3" />
          <XAxis
            dataKey="day"
            tickFormatter={(d: number) => (d ? fmtDay(d).replace(/, \d{4}$/, "") : "")}
            stroke="#8a8373"
            fontSize={11}
            minTickGap={40}
          />
          <YAxis stroke="#8a8373" fontSize={11} domain={["auto", "auto"]} width={52} tickFormatter={(v: number) => fmtNumber(v, digits)} />
          <Tooltip
            contentStyle={{ background: "#12110e", border: "1px solid #3a362c", borderRadius: 8, fontSize: 12 }}
            labelFormatter={(d) => (Number(d) ? `≈ ${fmtDay(Number(d))}` : "")}
            formatter={(v, name) => [typeof v === "number" ? fmtNumber(v, digits) : String(v), name]}
          />
          <Legend wrapperStyle={{ fontSize: 12 }} />
          <Line type="monotone" dataKey="value" name={valueLabel} stroke={color} dot={false} strokeWidth={1.8} isAnimationActive={false} />
          <Line
            type="monotone"
            dataKey="ma"
            name={maLabel}
            stroke="#ece6d6"
            strokeDasharray="5 4"
            dot={false}
            strokeWidth={1.4}
            connectNulls={false}
            isAnimationActive={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

export function BasketChart({ engine }: { engine: ReturnType<typeof useEngine> }) {
  const basketAssets = useMemo(() => {
    if (engine.basket && engine.basket[0].length) return engine.basket[0];
    return [deployment.spy, deployment.qqq].filter((a) => !isZero(a));
  }, [engine.basket]);
  const weights = useMemo(() => {
    if (engine.basket && engine.basket[1].length) return engine.basket[1].map(Number);
    return [6000, 4000];
  }, [engine.basket]);
  const series = useCloses(basketAssets);
  const maLong = engine.params ? Number(engine.params[0]) : 200;

  const { points, window, L } = useMemo(() => {
    const L = Math.min(...series.map((s) => s.closes.length));
    if (!Number.isFinite(L) || L < 2) return { points: [] as Point[], window: 0, L: 0 };
    const tails = series.map((s) => s.closes.slice(s.closes.length - L));
    const wsum = weights.reduce((a, b) => a + b, 0) || 1;
    const index = Array.from({ length: L }, (_, t) =>
      tails.reduce((acc, s, i) => acc + ((weights[i] ?? 0) / wsum) * (s[t] / s[0]), 0) * 100,
    );
    const lastDay = Math.max(...series.map((s) => s.lastDay));
    return { ...buildSeries(index, lastDay, maLong), L };
  }, [series, weights, maLong]);

  const label = basketAssets.map((a, i) => `${fmtNumber((weights[i] ?? 0) / 100, 0)}% ${symbolOf(a)}`).join(" / ");

  return (
    <Card title="Basket vs long moving average" right={<span className="text-xs text-ink-400">{label}</span>}>
      {points.length === 0 ? (
        <p className="py-10 text-center text-sm text-ink-400">{series.loading ? "Loading price history…" : "No recorded price history yet."}</p>
      ) : (
        <>
          <SeriesChart points={points} valueLabel="Basket index (start = 100)" maLabel={`${window}-session MA`} color="#7aa2f7" digits={1} />
          <p className="mt-2 text-xs text-ink-400">
            {L} daily closes from the on-chain PriceHistory contract, each series normalised to its first point and
            weighted per the engine basket. MA window = min({maLong}, {L}). Dates approximate (weekends skipped, holidays
            not). The engine itself uses a 3-close median spot; this chart is illustrative.
          </p>
        </>
      )}
    </Card>
  );
}

export function GoldChart({ engine }: { engine: ReturnType<typeof useEngine> }) {
  const gold = engine.goldAsset && !isZero(engine.goldAsset) ? engine.goldAsset : deployment.gld;
  const assets = useMemo(() => (isZero(gold) ? [] : [gold]), [gold]);
  const goldSeries = useCloses(assets);
  const s = goldSeries[0];
  const maLong = engine.params ? Number(engine.params[0]) : 200;
  const { points, window } = useMemo(
    () => (s && s.closes.length >= 2 ? buildSeries(s.closes, s.lastDay, maLong) : { points: [] as Point[], window: 0 }),
    [s, maLong],
  );
  return (
    <Card title="Gold vs moving average" right={<span className="text-xs text-ink-400">{symbolOf(gold)} · USD</span>}>
      {engine.signal && engine.signal.goldRatioLong === 0n && (
        <p className="mb-3 rounded-lg border border-ink-700 bg-ink-900 px-3 py-2 text-xs text-ink-300">
          Gold trend warming up: the gold price feed history is still too short for a trend reading. Until it fills, the
          defensive sleeve uses a neutral gold/T-bill split.
        </p>
      )}
      {points.length === 0 ? (
        <p className="py-10 text-center text-sm text-ink-400">{goldSeries.loading ? "Loading gold history…" : "No recorded gold history yet."}</p>
      ) : (
        <SeriesChart points={points} valueLabel={`${symbolOf(gold)} close ($)`} maLabel={`${window}-session MA`} color="#e8c25e" digits={2} />
      )}
    </Card>
  );
}

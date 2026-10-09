"use client";

import type { useEngine } from "@/hooks/useProtocol";
import { regimeOf } from "@/hooks/useProtocol";
import { fmtBps, fmtDateTime, fmtRatioPct } from "@/lib/format";
import { RegimeBadge, Pill } from "./Badges";
import { Card, Row } from "./ui";

export function SignalPanel({ engine }: { engine: ReturnType<typeof useEngine> }) {
  const s = engine.signal;
  const p = engine.params;
  const maLong = p ? Number(p[0]) : 200;
  const maShort = p ? Number(p[1]) : 50;
  const volWin = p ? Number(p[2]) : 20;
  const riskOn = regimeOf(engine);
  const goldWarming = s ? s.goldRatioLong === 0n : false;

  return (
    <Card title="Signal" right={<RegimeBadge riskOn={riskOn} warming={!!engine.warmup} />}>
      {!engine.enabled && <p className="text-sm text-ink-400">Signal engine not deployed.</p>}
      {engine.warmup && (
        <p className="mb-3 rounded-lg border border-ink-700 bg-ink-900 px-3 py-2 text-sm text-ink-300">
          Warming up: <span className="font-mono">{engine.warmup.have}</span> /{" "}
          <span className="font-mono">{engine.warmup.need}</span> sessions of price history recorded. The vaults stay in
          their defensive allocation until enough history exists.
        </p>
      )}
      {engine.signalError && !engine.warmup && (
        <p className="mb-3 text-sm text-bad">Could not compute the live signal right now.</p>
      )}
      <div className="divide-y divide-ink-800">
        <Row
          label="Regime (persisted)"
          value={riskOn === undefined ? "—" : riskOn ? "Risk-on" : "Risk-off"}
        />
        {s && s.riskOn !== engine.riskOnState && engine.riskOnState !== undefined && (
          <Row label="Live computed regime" value={s.riskOn ? "Risk-on (pending next rebalance)" : "Risk-off (pending next rebalance)"} />
        )}
        <Row label={`Basket vs ${maLong}-day MA`} value={s ? fmtRatioPct(s.basketRatioLong) : "—"} />
        <Row
          label={`${maShort}/${maLong} MA ratio`}
          value={
            s ? (
              <span className="inline-flex items-center gap-2">
                {fmtRatioPct(s.basketRatioShort)}
                <Pill tone={s.strongTrend ? "up" : "neutral"}>{s.strongTrend ? "strong" : "weak"} trend</Pill>
              </span>
            ) : (
              "—"
            )
          }
        />
        <Row label={`Realised vol (${volWin}d, annualised)`} value={s ? fmtBps(s.basketVolBps) : "—"} />
        <Row label="Stock scale (share of cap deployed)" value={s ? fmtBps(s.stockScaleBps) : "—"} />
        <Row
          label={`Gold vs ${maLong}-day MA`}
          value={s ? (goldWarming ? "warming up" : fmtRatioPct(s.goldRatioLong)) : "—"}
        />
        <Row label="Gold vol (annualised)" value={s && !goldWarming ? fmtBps(s.goldVolBps) : "—"} />
        <Row label="Gold share of defensive sleeve" value={s ? fmtBps(s.goldShareBps) : "—"} />
        <Row label="History (sessions)" value={s ? s.historyDays.toString() : engine.warmup ? engine.warmup.have : "—"} />
        <Row label="Computed at" value={s ? fmtDateTime(s.timestamp) : "—"} />
      </div>
    </Card>
  );
}

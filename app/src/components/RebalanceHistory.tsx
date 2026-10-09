"use client";

import { Fragment, useState } from "react";
import type { Address } from "viem";
import { txUrl } from "@/config/chain";
import { decimalsOf, symbolOf, USDG_DECIMALS } from "@/config/deployments";
import { LOG_SCAN_BLOCKS } from "@/config/env";
import { useRebalanceHistory, type RebalanceRow } from "@/hooks/useRebalanceHistory";
import { fmtBps, fmtDateTime, fmtNumber, fmtRatioPct, fmtUnits, fmtUsd, shortAddr } from "@/lib/format";
import { Pill } from "./Badges";
import { Card } from "./ui";

const BLOCKS_PER_DAY = 4 * 86400;

function TxLink({ hash, children }: { hash?: string; children?: React.ReactNode }) {
  if (!hash) return <span className="text-ink-400">—</span>;
  return (
    <a href={txUrl(hash)} target="_blank" rel="noreferrer" className="font-mono text-gold-400 hover:underline">
      {children ?? shortAddr(hash)} ↗
    </a>
  );
}

function StatusPill({ s }: { s: RebalanceRow["status"] }) {
  const tone = s === "completed" ? "up" : s === "running" ? "neutral" : "bad";
  return <Pill tone={tone}>{s}</Pill>;
}

function Detail({ r }: { r: RebalanceRow }) {
  const s = r.signal;
  return (
    <div className="grid gap-4 p-4 text-xs md:grid-cols-3">
      <div>
        <div className="mb-1.5 font-semibold text-ink-300">Signal that triggered it</div>
        {s ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
            <dt className="text-ink-400">Regime</dt>
            <dd>{s.riskOn ? "risk-on" : "risk-off"} · {s.strongTrend ? "strong" : "weak"} trend</dd>
            <dt className="text-ink-400">Basket vs long MA</dt>
            <dd className="font-mono">{fmtRatioPct(s.basketRatioLong)}</dd>
            <dt className="text-ink-400">Short/long MA</dt>
            <dd className="font-mono">{fmtRatioPct(s.basketRatioShort)}</dd>
            <dt className="text-ink-400">Basket vol</dt>
            <dd className="font-mono">{fmtBps(s.basketVolBps)}</dd>
            <dt className="text-ink-400">Gold vs long MA</dt>
            <dd className="font-mono">{s.goldRatioLong === 0n ? "warming up" : fmtRatioPct(s.goldRatioLong)}</dd>
            <dt className="text-ink-400">Gold vol</dt>
            <dd className="font-mono">{s.goldRatioLong === 0n ? "—" : fmtBps(s.goldVolBps)}</dd>
            <dt className="text-ink-400">Stock scale</dt>
            <dd className="font-mono">{fmtBps(s.stockScaleBps)}</dd>
            <dt className="text-ink-400">Gold share</dt>
            <dd className="font-mono">{fmtBps(s.goldShareBps)}</dd>
            <dt className="text-ink-400">History</dt>
            <dd className="font-mono">{s.historyDays.toString()} sessions</dd>
          </dl>
        ) : (
          <p className="text-ink-400">Start event outside the scanned range.</p>
        )}
      </div>
      <div>
        <div className="mb-1.5 font-semibold text-ink-300">Targets</div>
        {r.assets.length ? (
          <ul className="space-y-1">
            {r.assets.map((a, i) => (
              <li key={a} className="flex justify-between gap-3">
                <span>{symbolOf(a)}</span>
                <span className="font-mono">{fmtBps(r.targetBps[i] ?? 0)}</span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-ink-400">—</p>
        )}
        <div className="mb-1.5 mt-3 font-semibold text-ink-300">Chunks</div>
        {r.chunks.length ? (
          <ul className="space-y-1">
            {r.chunks.map((c) => (
              <li key={c.tx + c.chunk} className="flex justify-between gap-3">
                <span>
                  {c.chunk}/{c.total} · NAV {fmtUsd(c.navBefore, USDG_DECIMALS, 0)}
                </span>
                <TxLink hash={c.tx}>tx</TxLink>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-ink-400">none yet</p>
        )}
      </div>
      <div>
        <div className="mb-1.5 font-semibold text-ink-300">Trades</div>
        {r.trades.length ? (
          <ul className="space-y-1">
            {r.trades.map((t, i) => (
              <li key={t.tx + i} className="flex justify-between gap-3">
                <span className={t.failed ? "text-bad" : ""}>
                  {fmtUnits(t.amountIn, decimalsOf(t.tokenIn), 4)} {symbolOf(t.tokenIn)} →{" "}
                  {t.failed ? "failed" : `${fmtUnits(t.amountOut, decimalsOf(t.tokenOut), 4)} ${symbolOf(t.tokenOut)}`}
                </span>
                <TxLink hash={t.tx}>tx</TxLink>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-ink-400">none</p>
        )}
      </div>
    </div>
  );
}

export function RebalanceHistory({ vault }: { vault: Address }) {
  const h = useRebalanceHistory(vault);
  const [open, setOpen] = useState<string | null>(null);
  const days = Number(h.scannedBlocks) / BLOCKS_PER_DAY;

  return (
    <Card
      title="Rebalance history"
      right={
        h.enabled ? (
          <span className="text-xs text-ink-400">
            {h.loading ? `scanning… ${Math.round(h.progress * 100)}%` : h.done ? "full history" : `showing last ≈${fmtNumber(days, 1)} days`}
          </span>
        ) : undefined
      }
    >
      {!h.enabled ? (
        <p className="text-sm text-ink-400">Vault not deployed yet.</p>
      ) : (
        <>
          <div className="-mx-5 overflow-x-auto">
            <table className="w-full min-w-[720px] text-left text-sm">
              <thead className="border-b border-ink-700 text-xs uppercase tracking-wider text-ink-400">
                <tr>
                  <th className="px-5 py-2 font-medium">#</th>
                  <th className="px-2 py-2 font-medium">Signal time</th>
                  <th className="px-2 py-2 font-medium">Regime</th>
                  <th className="px-2 py-2 font-medium">Basket vs MA</th>
                  <th className="px-2 py-2 font-medium">Vol</th>
                  <th className="px-2 py-2 font-medium">Stock scale</th>
                  <th className="px-2 py-2 font-medium">NAV</th>
                  <th className="px-2 py-2 font-medium">Status</th>
                  <th className="px-5 py-2 font-medium">Tx</th>
                </tr>
              </thead>
              <tbody>
                {h.rows.length === 0 && !h.loading && (
                  <tr>
                    <td colSpan={9} className="px-5 py-6 text-center text-ink-400">
                      No rebalances in the scanned range.
                    </td>
                  </tr>
                )}
                {h.rows.map((r) => {
                  const k = r.id.toString();
                  const isOpen = open === k;
                  return (
                    <Fragment key={k}>
                      <tr
                        className="cursor-pointer border-b border-ink-800 hover:bg-ink-800/40"
                        onClick={() => setOpen(isOpen ? null : k)}
                      >
                        <td className="px-5 py-2 font-mono">
                          <span className="mr-1 text-ink-400">{isOpen ? "▾" : "▸"}</span>
                          {k}
                        </td>
                        <td className="px-2 py-2">{r.signal ? fmtDateTime(r.signal.timestamp) : "—"}</td>
                        <td className="px-2 py-2">
                          {r.signal ? <Pill tone={r.signal.riskOn ? "up" : "down"}>{r.signal.riskOn ? "risk-on" : "risk-off"}</Pill> : "—"}
                        </td>
                        <td className="px-2 py-2 font-mono">{r.signal ? fmtRatioPct(r.signal.basketRatioLong) : "—"}</td>
                        <td className="px-2 py-2 font-mono">{r.signal ? fmtBps(r.signal.basketVolBps) : "—"}</td>
                        <td className="px-2 py-2 font-mono">{r.signal ? fmtBps(r.signal.stockScaleBps) : "—"}</td>
                        <td className="px-2 py-2 font-mono">{fmtUsd(r.navEnd ?? r.navStart, USDG_DECIMALS, 0)}</td>
                        <td className="px-2 py-2">
                          <StatusPill s={r.status} />
                        </td>
                        <td className="px-5 py-2" onClick={(e) => e.stopPropagation()}>
                          <TxLink hash={r.startTx ?? r.endTx} />
                        </td>
                      </tr>
                      {isOpen && (
                        <tr className="border-b border-ink-800 bg-ink-900/60">
                          <td colSpan={9}>
                            <Detail r={r} />
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
          <div className="mt-4 flex flex-wrap items-center gap-3 text-xs text-ink-400">
            {h.error && <span className="text-bad">RPC error while scanning: {h.error}</span>}
            {!h.done && (
              <button type="button" className="btn btn-ghost px-3 py-1.5 text-xs" disabled={h.loading} onClick={h.loadMore}>
                {h.loading ? "Scanning…" : `Load older (${fmtNumber(Number(LOG_SCAN_BLOCKS) / BLOCKS_PER_DAY, 1)} more days)`}
              </button>
            )}
            <span>Events read directly from the vault contract in 50k-block pages. Click a row for the full signal, targets and trades.</span>
          </div>
        </>
      )}
    </Card>
  );
}


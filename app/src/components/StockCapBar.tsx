import { fmtBps } from "@/lib/format";

/** Current stock weight vs the vault's immutable stock cap (both bps). */
export function StockCapBar({ weightBps, capBps }: { weightBps: number | undefined; capBps: number }) {
  const w = Math.max(0, Math.min(10_000, weightBps ?? 0));
  return (
    <div>
      <div className="mb-1.5 flex justify-between text-xs text-ink-400">
        <span>
          Stocks now <span className="font-mono text-ink-100">{weightBps === undefined ? "—" : fmtBps(w)}</span>
        </span>
        <span>
          cap <span className="font-mono text-gold-300">{fmtBps(capBps, 0)}</span>
        </span>
      </div>
      <div className="relative h-2.5 overflow-hidden rounded-full bg-ink-800">
        <div className="absolute inset-y-0 left-0 bg-gold-700/35" style={{ width: `${capBps / 100}%` }} />
        <div
          className="absolute inset-y-0 left-0 rounded-full bg-gradient-to-r from-[#7aa2f7] to-[#a78bfa]"
          style={{ width: `${w / 100}%` }}
        />
        <div className="absolute inset-y-0 w-0.5 bg-gold-400" style={{ left: `calc(${capBps / 100}% - 1px)` }} />
      </div>
    </div>
  );
}

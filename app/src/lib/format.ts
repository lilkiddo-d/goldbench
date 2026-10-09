import { formatUnits } from "viem";

const nf = (max: number, min = 0) =>
  new Intl.NumberFormat("en-US", { maximumFractionDigits: max, minimumFractionDigits: min });

/** bigint-safe: formats via viem formatUnits, then groups digits as strings (no float rounding of the integer part). */
export function fmtUnits(value: bigint | undefined, decimals: number, maxFrac = 2, minFrac = 0): string {
  if (value === undefined) return "—";
  const s = formatUnits(value, decimals);
  const [int, frac = ""] = s.split(".");
  const neg = int.startsWith("-");
  const intAbs = neg ? int.slice(1) : int;
  const grouped = intAbs.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  let f = frac.slice(0, maxFrac).replace(/0+$/, "");
  if (f === "" && intAbs === "0" && value !== 0n && maxFrac > 0) {
    return (neg ? ">-" : "<") + "0." + "0".repeat(maxFrac - 1) + "1";
  }
  if (f.length < minFrac) f = f.padEnd(minFrac, "0");
  return (neg ? "-" : "") + grouped + (f ? "." + f : "");
}

export const fmtUsd = (v: bigint | undefined, decimals = 6, maxFrac = 2) =>
  v === undefined ? "—" : "$" + fmtUnits(v, decimals, maxFrac, Math.min(2, maxFrac));

/** bps → "12.3%" */
export function fmtBps(bps: bigint | number | undefined, frac = 1): string {
  if (bps === undefined) return "—";
  return nf(frac, frac).format(Number(bps) / 100) + "%";
}

/** 1e18-scaled ratio → signed % distance from 1.0 ("+3.20%" / "-1.00%") */
export function fmtRatioPct(r: bigint | undefined, frac = 2): string {
  if (r === undefined) return "—";
  const pct = (Number(r) / 1e18 - 1) * 100;
  return (pct >= 0 ? "+" : "") + nf(frac, frac).format(pct) + "%";
}

export function fmtNumber(n: number | undefined, frac = 2): string {
  if (n === undefined || !Number.isFinite(n)) return "—";
  return nf(frac).format(n);
}

export const shortAddr = (a?: string) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");

export function fmtDateTime(ts: bigint | number | undefined): string {
  if (ts === undefined) return "—";
  const n = Number(ts);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** Days since 1970-01-01 (New York calendar day) → "Oct 8, 2026" */
export function fmtDay(day: number): string {
  return new Date(day * 86_400_000).toLocaleDateString("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function fmtDuration(sec: number): string {
  if (sec <= 0) return "now";
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

"use client";

import { useMarketOpen } from "@/hooks/useProtocol";

export function Pill({ tone, children }: { tone: "up" | "down" | "neutral" | "bad"; children: React.ReactNode }) {
  const cls = {
    up: "border-up/40 bg-up/10 text-up",
    down: "border-down/40 bg-down/10 text-down",
    bad: "border-bad/40 bg-bad/10 text-bad",
    neutral: "border-ink-600 bg-ink-800 text-ink-300",
  }[tone];
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2.5 py-0.5 text-xs font-semibold ${cls}`}>
      {children}
    </span>
  );
}

const Dot = ({ className }: { className: string }) => <span className={`h-1.5 w-1.5 rounded-full ${className}`} />;

export function RegimeBadge({ riskOn, warming }: { riskOn: boolean | undefined; warming?: boolean }) {
  if (warming && riskOn === undefined) return <Pill tone="neutral">Warming up</Pill>;
  if (riskOn === undefined) return <Pill tone="neutral">Regime —</Pill>;
  return riskOn ? (
    <Pill tone="up">
      <Dot className="bg-up" /> Risk-on
    </Pill>
  ) : (
    <Pill tone="down">
      <Dot className="bg-down" /> Risk-off
    </Pill>
  );
}

export function MarketBadge() {
  const { data, isError } = useMarketOpen();
  if (data === undefined || isError) return <Pill tone="neutral">US market —</Pill>;
  return data ? (
    <Pill tone="up">
      <Dot className="bg-up" /> US market open
    </Pill>
  ) : (
    <Pill tone="neutral">
      <Dot className="bg-ink-400" /> US market closed
    </Pill>
  );
}

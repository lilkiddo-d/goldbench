"use client";

import Link from "next/link";
import { VAULTS } from "@/config/vaults";
import { regimeOf, useEngine } from "@/hooks/useProtocol";
import { VaultCard } from "@/components/VaultCard";
import { RegimeBadge } from "@/components/Badges";
import { fmtRatioPct } from "@/lib/format";

export default function HomePage() {
  const engine = useEngine();
  const riskOn = regimeOf(engine);

  return (
    <div className="space-y-10">
      <section className="grid gap-6 md:grid-cols-[1.4fr_1fr] md:items-end">
        <div>
          <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
            Sit on <span className="gold-text">gold</span> when the trend breaks.
            <br className="hidden sm:block" /> Ride stocks when it holds.
          </h1>
          <p className="mt-4 max-w-xl text-ink-300">
            Goldbench vaults take USDG and rotate between a tokenized S&amp;P 500 / Nasdaq-100 basket and a defensive
            sleeve of tokenized gold and T-bills, following a transparent on-chain trend and volatility signal. Rebalances
            run at most weekly, during US market hours.
          </p>
        </div>
        <div className="card flex flex-col gap-2 p-4 text-sm">
          <div className="flex items-center justify-between">
            <span className="text-ink-400">Current regime</span>
            <RegimeBadge riskOn={riskOn} warming={!!engine.warmup} />
          </div>
          <div className="flex items-center justify-between">
            <span className="text-ink-400">Basket vs long MA</span>
            <span className="font-mono">{engine.signal ? fmtRatioPct(engine.signal.basketRatioLong) : "—"}</span>
          </div>
          {engine.warmup && (
            <p className="text-xs text-ink-400">
              Signal warming up: {engine.warmup.have}/{engine.warmup.need} sessions recorded.
            </p>
          )}
          <Link href="/risk" className="text-xs text-gold-400 hover:underline">
            Read the risk disclosure →
          </Link>
        </div>
      </section>

      <section className="grid gap-6 lg:grid-cols-3">
        {VAULTS.map((v) => (
          <VaultCard key={v.slug} meta={v} riskOn={riskOn} warming={!!engine.warmup} />
        ))}
      </section>
    </div>
  );
}

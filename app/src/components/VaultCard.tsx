"use client";

import Link from "next/link";
import { USDG_DECIMALS } from "@/config/deployments";
import { MGMT_FEE_LABEL, type VaultMeta } from "@/config/vaults";
import { useVaultCore } from "@/hooks/useProtocol";
import { fmtBps, fmtUnits, fmtUsd } from "@/lib/format";
import { AllocationPie } from "./AllocationPie";
import { Pill, RegimeBadge } from "./Badges";
import { StockCapBar } from "./StockCapBar";
import { Skeleton, Stat } from "./ui";

export function VaultCard({ meta, riskOn, warming }: { meta: VaultMeta; riskOn: boolean | undefined; warming: boolean }) {
  const v = useVaultCore(meta.address);
  const cap = v.stockCapBps ?? meta.capBps;
  const loading = v.enabled && v.isLoading;

  return (
    <article className="card flex flex-col gap-5 p-5 transition hover:border-gold-700">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-xl font-bold">
            <span className="gold-text">{meta.name}</span>
          </h3>
          <p className="mt-1 text-sm text-ink-400">{meta.tagline}</p>
        </div>
        <div className="flex flex-col items-end gap-1.5">
          <RegimeBadge riskOn={riskOn} warming={warming} />
          {v.paused && <Pill tone="bad">Paused</Pill>}
        </div>
      </header>

      <div className="grid grid-cols-2 gap-4">
        <Stat label="TVL" value={loading ? <Skeleton /> : fmtUsd(v.totalAssets, USDG_DECIMALS, 0)} />
        <Stat
          label="Share price"
          value={loading ? <Skeleton /> : v.sharePrice === undefined ? "—" : fmtUnits(v.sharePrice, USDG_DECIMALS, 4, 4)}
          sub="USDG per share"
        />
      </div>

      <AllocationPie allocation={v.allocation} size={128} />

      <StockCapBar weightBps={v.stockWeightBps === undefined ? undefined : Number(v.stockWeightBps)} capBps={cap} />

      <footer className="mt-auto flex items-center justify-between border-t border-ink-700 pt-4 text-xs text-ink-400">
        <span>
          Fee {v.mgmtFeeBps !== undefined ? `${fmtBps(v.mgmtFeeBps, 2)} / yr` : MGMT_FEE_LABEL} · no performance fee
        </span>
        <Link href={`/vault/${meta.slug}`} className="btn btn-ghost px-3 py-1.5 text-xs">
          Open vault →
        </Link>
      </footer>
    </article>
  );
}

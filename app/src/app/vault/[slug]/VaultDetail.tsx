"use client";

import Link from "next/link";
import { addressUrl } from "@/config/chain";
import { deployment, USDG_DECIMALS } from "@/config/deployments";
import { MGMT_FEE_LABEL, vaultBySlug, type VaultSlug } from "@/config/vaults";
import { regimeOf, useEngine, useVaultCore } from "@/hooks/useProtocol";
import { AllocationPie } from "@/components/AllocationPie";
import { Pill, RegimeBadge } from "@/components/Badges";
import { DepositPanel } from "@/components/DepositPanel";
import { PlanStatus } from "@/components/PlanStatus";
import { BasketChart, GoldChart } from "@/components/PriceCharts";
import { RebalanceHistory } from "@/components/RebalanceHistory";
import { SignalPanel } from "@/components/SignalPanel";
import { StockCapBar } from "@/components/StockCapBar";
import { Card, Stat } from "@/components/ui";
import { WithdrawPanel } from "@/components/WithdrawPanel";
import { fmtBps, fmtUnits, fmtUsd } from "@/lib/format";

export function VaultDetail({ slug }: { slug: VaultSlug }) {
  const meta = vaultBySlug(slug)!;
  const v = useVaultCore(meta.address);
  const engine = useEngine();
  const cap = v.stockCapBps ?? meta.capBps;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <Link href="/" className="text-xs text-ink-400 hover:text-ink-100">
            ← All vaults
          </Link>
          <h1 className="mt-1 text-3xl font-bold">
            <span className="gold-text">{meta.name}</span> vault
          </h1>
          <p className="mt-1 text-sm text-ink-400">
            {meta.tagline}
            {!deployment.placeholder && (
              <>
                {" "}
                ·{" "}
                <a className="text-gold-400 hover:underline" href={addressUrl(meta.address)} target="_blank" rel="noreferrer">
                  {v.symbol ?? "contract"} ↗
                </a>
              </>
            )}
          </p>
        </div>
        <div className="flex gap-2">
          <RegimeBadge riskOn={regimeOf(engine)} warming={!!engine.warmup} />
          {v.paused && <Pill tone="bad">Paused</Pill>}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <div className="card p-4">
          <Stat label="TVL" value={fmtUsd(v.totalAssets, USDG_DECIMALS, 0)} />
        </div>
        <div className="card p-4">
          <Stat label="Share price" value={v.sharePrice === undefined ? "—" : fmtUnits(v.sharePrice, USDG_DECIMALS, 4, 4)} sub="USDG / share" />
        </div>
        <div className="card p-4">
          <Stat label="Stock cap" value={fmtBps(cap, 0)} sub={`now ${v.stockWeightBps !== undefined ? fmtBps(v.stockWeightBps) : "—"}`} />
        </div>
        <div className="card p-4">
          <Stat
            label="Management fee"
            value={v.mgmtFeeBps !== undefined ? `${fmtBps(v.mgmtFeeBps, 2)}/yr` : MGMT_FEE_LABEL}
            sub="no performance fee"
          />
        </div>
      </div>

      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        <div className="space-y-6">
          <Card title="Allocation">
            <AllocationPie allocation={v.allocation} size={180} />
            <div className="mt-5">
              <StockCapBar weightBps={v.stockWeightBps === undefined ? undefined : Number(v.stockWeightBps)} capBps={cap} />
            </div>
          </Card>
          <BasketChart engine={engine} />
          <GoldChart engine={engine} />
        </div>
        <div className="space-y-6">
          <DepositPanel vault={meta.address} paused={v.paused} />
          <WithdrawPanel vault={meta.address} />
          <SignalPanel engine={engine} />
          <PlanStatus vault={meta.address} />
        </div>
      </div>

      <RebalanceHistory vault={meta.address} />
    </div>
  );
}

"use client";

import { useMemo, useState } from "react";
import { erc20Abi, type Address } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { projectTokenHooksAbi, signalEngineAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero, SHARE_DECIMALS } from "@/config/deployments";
import { PROJECT_TOKEN } from "@/config/env";
import { VAULTS } from "@/config/vaults";
import { useTx } from "@/hooks/useTx";
import { errorAbi } from "@/lib/abis";
import { fmtBps, fmtDateTime, fmtUnits } from "@/lib/format";
import { parseAmount } from "@/components/DepositPanel";
import { Pill } from "@/components/Badges";
import { Card, Row, Stat, TxStatus } from "@/components/ui";

const chainId = robinhoodChain.id;
const hooksAbi = [...projectTokenHooksAbi, ...errorAbi] as unknown as typeof projectTokenHooksAbi;

type ParamMeta = { id: number; label: string; min: number; max: number; unit: "days" | "bps" | "sessions" };
export const PARAMS: ParamMeta[] = [
  { id: 0, label: "Long moving average", min: 100, max: 250, unit: "sessions" },
  { id: 1, label: "Short moving average", min: 10, max: 100, unit: "sessions" },
  { id: 2, label: "Volatility window", min: 10, max: 60, unit: "sessions" },
  { id: 3, label: "Target volatility", min: 500, max: 4000, unit: "bps" },
  { id: 4, label: "Minimum vol scale", min: 0, max: 10000, unit: "bps" },
  { id: 5, label: "Hysteresis band", min: 0, max: 500, unit: "bps" },
  { id: 6, label: "Weak-trend scale", min: 0, max: 10000, unit: "bps" },
  { id: 7, label: "Gold share when gold uptrend", min: 0, max: 10000, unit: "bps" },
  { id: 8, label: "Gold share when gold downtrend", min: 0, max: 10000, unit: "bps" },
  { id: 9, label: "Minimum history", min: 30, max: 250, unit: "sessions" },
];

const fmtParam = (p: ParamMeta | undefined, v: bigint | number | undefined) =>
  v === undefined || !p ? "—" : p.unit === "bps" ? `${fmtBps(v, 2)} (${v.toString()} bps)` : `${v.toString()} ${p.unit}`;

type Proposal = readonly [number, bigint, Address, bigint, bigint, bigint, bigint, bigint, boolean];

export function StakeView() {
  const { address } = useAccount();
  const hooks = deployment.projectTokenHooks;
  const token = PROJECT_TOKEN!;
  const enabled = !deployment.placeholder && !isZero(hooks);
  const who = address ?? token;
  const tx = useTx();
  const [amt, setAmt] = useState("");
  const [pid, setPid] = useState(0);
  const [pval, setPval] = useState("");

  const h = { address: hooks, abi: projectTokenHooksAbi, chainId } as const;
  const base = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [who], chainId },
      { address: token, abi: erc20Abi, functionName: "allowance", args: [who, hooks], chainId },
      { address: token, abi: erc20Abi, functionName: "decimals", chainId },
      { address: token, abi: erc20Abi, functionName: "symbol", chainId },
      { ...h, functionName: "staked", args: [who] },
      { ...h, functionName: "totalStaked" },
      { ...h, functionName: "lockedUntil", args: [who] },
      { ...h, functionName: "proposalThreshold" },
      { ...h, functionName: "proposalCount" },
      { ...h, functionName: "quorumBps" },
      { ...h, functionName: "votingPeriod" },
      { address: deployment.signalEngine, abi: signalEngineAbi, functionName: "params", chainId },
    ],
    query: { enabled, refetchInterval: 20_000 },
  });
  const d = base.data ?? [];
  const r = <T,>(i: number) => d[i]?.result as T | undefined;
  const balance = address ? r<bigint>(0) : undefined;
  const allowance = address ? r<bigint>(1) : undefined;
  const dec = r<number>(2) ?? 18;
  const sym = r<string>(3) ?? "GBEN";
  const staked = address ? r<bigint>(4) : undefined;
  const totalStaked = r<bigint>(5);
  const lockedUntil = address ? r<bigint>(6) : undefined;
  const threshold = r<bigint>(7);
  const count = r<bigint>(8) ?? 0n;
  const quorumBps = r<number>(9);
  const params = r<readonly bigint[]>(11);

  const amount = parseAmount(amt, dec);

  const claims = useReadContracts({
    allowFailure: true,
    contracts: VAULTS.map((v) => ({ ...h, functionName: "claimable", args: [v.address, who] }) as const),
    query: { enabled: enabled && !!address, refetchInterval: 30_000 },
  });

  const ids = useMemo(() => {
    const out: bigint[] = [];
    for (let i = count; i >= 1n && out.length < 25; i--) out.push(i);
    return out;
  }, [count]);
  const props = useReadContracts({
    allowFailure: true,
    contracts: ids.flatMap((id) => [
      { ...h, functionName: "proposals", args: [id] } as const,
      { ...h, functionName: "hasVoted", args: [id, who] } as const,
    ]),
    query: { enabled: enabled && ids.length > 0, refetchInterval: 30_000 },
  });

  const now = BigInt(Math.floor(Date.now() / 1000));
  const locked = lockedUntil !== undefined && lockedUntil > now;
  const needsApproval = amount !== undefined && allowance !== undefined && allowance < amount;
  const busy = tx.busy || !address || !enabled;

  const meta = PARAMS[pid];
  const pvalNum = /^\d+$/.test(pval.trim()) ? BigInt(pval.trim()) : undefined;
  const pvalOk = pvalNum !== undefined && meta && pvalNum >= BigInt(meta.min) && pvalNum <= BigInt(meta.max);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">
          Stake <span className="gold-text">${sym}</span>
        </h1>
        <p className="mt-1 max-w-2xl text-sm text-ink-400">
          Stakers receive a share of vault management fees as fee rebates (paid in vault shares) and can propose and vote on
          signal parameters. Passed proposals are queued on the timelock and stay within hard-coded bounds.
        </p>
      </div>

      {!enabled && <p className="text-sm text-ink-400">Staking contract not deployed yet.</p>}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Stake / unstake">
          <div className="mb-4 grid grid-cols-3 gap-4">
            <Stat label="Wallet" value={fmtUnits(balance, dec, 2)} />
            <Stat label="Staked" value={fmtUnits(staked, dec, 2)} />
            <Stat label="Total staked" value={fmtUnits(totalStaked, dec, 0)} />
          </div>
          <div className="flex gap-2">
            <input className="input" inputMode="decimal" placeholder={`Amount ${sym}`} value={amt} onChange={(e) => setAmt(e.target.value)} />
            <button
              type="button"
              className="btn btn-ghost"
              disabled={!balance}
              onClick={() => balance !== undefined && setAmt(fmtUnits(balance, dec, dec).replace(/,/g, ""))}
            >
              Max
            </button>
          </div>
          <div className="mt-3 grid grid-cols-3 gap-2">
            <button
              type="button"
              className="btn btn-ghost"
              disabled={busy || !amount || !needsApproval}
              onClick={() => amount && tx.run(`Approve ${sym}`, { address: token, abi: erc20Abi, functionName: "approve", args: [hooks, amount] })}
            >
              Approve
            </button>
            <button
              type="button"
              className="btn btn-gold"
              disabled={busy || !amount || needsApproval || (balance !== undefined && amount > balance)}
              onClick={() => amount && tx.run("Stake", { address: hooks, abi: hooksAbi, functionName: "stake", args: [amount] })}
            >
              Stake
            </button>
            <button
              type="button"
              className="btn btn-ghost"
              disabled={busy || !amount || locked || (staked !== undefined && amount > staked)}
              onClick={() => amount && tx.run("Unstake", { address: hooks, abi: hooksAbi, functionName: "unstake", args: [amount] })}
            >
              Unstake
            </button>
          </div>
          {locked && (
            <p className="mt-2 text-xs text-down">Stake locked until {fmtDateTime(lockedUntil)} (you voted on an open proposal).</p>
          )}
          <TxStatus state={tx.state} />
        </Card>

        <Card title="Fee rebates">
          <div className="divide-y divide-ink-800">
            {VAULTS.map((v, i) => {
              const c = claims.data?.[i]?.result as bigint | undefined;
              return (
                <div key={v.slug} className="flex items-center justify-between gap-3 py-2 text-sm">
                  <span>{v.name}</span>
                  <span className="flex items-center gap-3">
                    <span className="font-mono">{address ? `${fmtUnits(c, SHARE_DECIMALS, 6)} shares` : "—"}</span>
                    <button
                      type="button"
                      className="btn btn-ghost px-2.5 py-1 text-xs"
                      disabled={busy || !c}
                      onClick={() => tx.run(`Claim ${v.name}`, { address: hooks, abi: hooksAbi, functionName: "claimRebate", args: [v.address] })}
                    >
                      Claim
                    </button>
                  </span>
                </div>
              );
            })}
          </div>
          <p className="mt-3 text-xs text-ink-400">Rebates are paid in vault shares, which you can redeem like any deposit.</p>
        </Card>
      </div>

      <Card title="Propose a parameter change">
        <div className="grid gap-3 md:grid-cols-[1fr_200px_auto] md:items-end">
          <label className="text-xs text-ink-400">
            Parameter
            <select className="input mt-1 font-sans text-sm" value={pid} onChange={(e) => setPid(Number(e.target.value))}>
              {PARAMS.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.id} · {p.label}
                </option>
              ))}
            </select>
          </label>
          <label className="text-xs text-ink-400">
            New value ({meta.unit})
            <input className="input mt-1" inputMode="numeric" placeholder={`${meta.min}–${meta.max}`} value={pval} onChange={(e) => setPval(e.target.value)} />
          </label>
          <button
            type="button"
            className="btn btn-gold"
            disabled={busy || !pvalOk || (threshold !== undefined && staked !== undefined && staked < threshold)}
            onClick={() => pvalNum !== undefined && tx.run("Propose", { address: hooks, abi: hooksAbi, functionName: "propose", args: [pid, pvalNum] })}
          >
            Propose
          </button>
        </div>
        <div className="mt-3 grid gap-x-6 text-xs text-ink-400 sm:grid-cols-3">
          <span>Current: <span className="font-mono text-ink-100">{fmtParam(meta, params?.[pid])}</span></span>
          <span>Bounds: <span className="font-mono text-ink-100">{meta.min}–{meta.max} {meta.unit}</span></span>
          <span>Threshold: <span className="font-mono text-ink-100">{fmtUnits(threshold, dec, 2)} {sym}</span> staked</span>
        </div>
        <p className="mt-2 text-xs text-ink-400">
          The engine also rejects inconsistent sets (short MA must be below long MA; minimum history must exceed the vol
          window, be at least the short MA and at most the long MA). Quorum: {quorumBps !== undefined ? fmtBps(quorumBps, 0) : "—"} of stake at creation.
        </p>
      </Card>

      <Card title={`Proposals (${count.toString()})`}>
        {ids.length === 0 ? (
          <p className="text-sm text-ink-400">No proposals yet.</p>
        ) : (
          <div className="space-y-3">
            {ids.map((id, i) => {
              const p = props.data?.[2 * i]?.result as Proposal | undefined;
              const voted = address ? (props.data?.[2 * i + 1]?.result as boolean | undefined) : undefined;
              if (!p) return null;
              const [paramId, value, proposer, start, end, forV, against, quorum, queued] = p;
              const pm = PARAMS[paramId];
              const open = now < end;
              const passed = !open && forV > against && forV >= quorum && forV > 0n;
              return (
                <div key={id.toString()} className="rounded-xl border border-ink-700 bg-ink-900/50 p-4">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="text-sm">
                      <span className="font-mono text-ink-400">#{id.toString()}</span>{" "}
                      <span className="font-semibold">{pm?.label ?? `param ${paramId}`}</span> →{" "}
                      <span className="font-mono text-gold-300">{fmtParam(pm, value)}</span>
                    </div>
                    {queued ? (
                      <Pill tone="up">queued</Pill>
                    ) : open ? (
                      <Pill tone="neutral">voting until {fmtDateTime(end)}</Pill>
                    ) : passed ? (
                      <Pill tone="up">passed</Pill>
                    ) : (
                      <Pill tone="bad">failed</Pill>
                    )}
                  </div>
                  <div className="mt-2 grid gap-x-6 sm:grid-cols-2">
                    <Row label="For / against" value={`${fmtUnits(forV, dec, 2)} / ${fmtUnits(against, dec, 2)}`} />
                    <Row label="Quorum" value={fmtUnits(quorum, dec, 2)} />
                    <Row label="Proposer" value={`${proposer.slice(0, 6)}…${proposer.slice(-4)}`} />
                    <Row label="Started" value={fmtDateTime(start)} />
                  </div>
                  <div className="mt-3 flex flex-wrap gap-2">
                    {open && (
                      <>
                        <button
                          type="button"
                          className="btn btn-ghost px-3 py-1.5 text-xs"
                          disabled={busy || voted || !staked}
                          onClick={() => tx.run(`Vote for #${id}`, { address: hooks, abi: hooksAbi, functionName: "vote", args: [id, true] })}
                        >
                          Vote for
                        </button>
                        <button
                          type="button"
                          className="btn btn-ghost px-3 py-1.5 text-xs"
                          disabled={busy || voted || !staked}
                          onClick={() => tx.run(`Vote against #${id}`, { address: hooks, abi: hooksAbi, functionName: "vote", args: [id, false] })}
                        >
                          Vote against
                        </button>
                        {voted && <span className="self-center text-xs text-ink-400">You voted. Your stake is locked until voting ends.</span>}
                      </>
                    )}
                    {passed && !queued && (
                      <button
                        type="button"
                        className="btn btn-gold px-3 py-1.5 text-xs"
                        disabled={busy}
                        onClick={() => tx.run(`Queue #${id}`, { address: hooks, abi: hooksAbi, functionName: "queue", args: [id] })}
                      >
                        Queue on timelock
                      </button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}
        <TxStatus state={tx.state} />
      </Card>
    </div>
  );
}

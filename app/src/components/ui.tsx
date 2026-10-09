"use client";

import type { ReactNode } from "react";
import { txUrl } from "@/config/chain";
import type { TxState } from "@/hooks/useTx";

export function Card({ title, right, children, className = "" }: { title?: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`card p-5 ${className}`}>
      {(title || right) && (
        <div className="mb-4 flex items-center justify-between gap-3">
          {title && <h2 className="text-sm font-semibold uppercase tracking-wider text-ink-300">{title}</h2>}
          {right}
        </div>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, sub, hint }: { label: string; value: ReactNode; sub?: ReactNode; hint?: string }) {
  return (
    <div title={hint}>
      <div className="text-xs text-ink-400">{label}</div>
      <div className="mt-0.5 font-mono text-lg font-semibold text-ink-100">{value}</div>
      {sub && <div className="text-xs text-ink-400">{sub}</div>}
    </div>
  );
}

export function Row({ label, value }: { label: ReactNode; value: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-4 py-1.5 text-sm">
      <span className="text-ink-400">{label}</span>
      <span className="text-right font-mono text-ink-100">{value}</span>
    </div>
  );
}

export function TxStatus({ state }: { state: TxState }) {
  if (state.status === "idle") return null;
  const text = {
    simulating: "Checking transaction…",
    signing: "Confirm in your wallet…",
    confirming: "Waiting for confirmation…",
    success: "Confirmed.",
    error: state.error,
    idle: "",
  }[state.status];
  const tone = state.status === "error" ? "text-bad" : state.status === "success" ? "text-up" : "text-ink-300";
  return (
    <div className={`mt-3 rounded-lg border border-ink-700 bg-ink-900/70 px-3 py-2 text-xs ${tone}`}>
      {state.label && <span className="font-semibold">{state.label}: </span>}
      {text}
      {state.hash && (
        <a className="ml-2 text-gold-400 hover:underline" href={txUrl(state.hash)} target="_blank" rel="noreferrer">
          view tx ↗
        </a>
      )}
    </div>
  );
}

export function Skeleton({ className = "h-4 w-20" }: { className?: string }) {
  return <span className={`inline-block animate-pulse rounded bg-ink-700/60 ${className}`} />;
}

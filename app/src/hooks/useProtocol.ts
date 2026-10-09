"use client";

import { useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { marketClockAbi, rotationVaultAbi, signalEngineAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero } from "@/config/deployments";
import { decodeRevert } from "@/lib/errors";

const chainId = robinhoodChain.id;
const live = !deployment.placeholder;

/** Global signal-engine state shared by every vault. */
export function useEngine() {
  const engine = deployment.signalEngine;
  const enabled = live && !isZero(engine);

  const signal = useReadContract({
    address: engine,
    abi: signalEngineAbi,
    functionName: "computeSignal",
    chainId,
    query: { enabled, refetchInterval: 60_000, retry: (n, e) => n < 2 && !decodeRevert(e) },
  });

  const statics = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: engine, abi: signalEngineAbi, functionName: "riskOnState", chainId },
      { address: engine, abi: signalEngineAbi, functionName: "params", chainId },
      { address: engine, abi: signalEngineAbi, functionName: "basket", chainId },
      { address: engine, abi: signalEngineAbi, functionName: "goldAsset", chainId },
      { address: engine, abi: signalEngineAbi, functionName: "tbillAsset", chainId },
    ],
    query: { enabled, refetchInterval: 120_000 },
  });

  const [riskOnState, params, basket, goldAsset, tbillAsset] = statics.data ?? [];
  const warmup = decodeRevert(signal.error);

  return {
    enabled,
    signal: signal.data,
    signalError: signal.error,
    /** set when computeSignal reverts InsufficientHistory(have, need) */
    warmup:
      warmup?.name === "InsufficientHistory"
        ? { have: Number(warmup.args[0]), need: Number(warmup.args[1]) }
        : undefined,
    riskOnState: riskOnState?.result as boolean | undefined,
    params: params?.result as readonly bigint[] | undefined,
    basket: basket?.result as readonly [readonly Address[], readonly number[]] | undefined,
    goldAsset: goldAsset?.result as Address | undefined,
    tbillAsset: tbillAsset?.result as Address | undefined,
    isLoading: signal.isLoading || statics.isLoading,
  };
}

/** Regime: prefer persisted riskOnState (what the vaults act on); fall back to the live computed signal. */
export function regimeOf(e: ReturnType<typeof useEngine>): boolean | undefined {
  return e.riskOnState ?? e.signal?.riskOn;
}

export function useMarketOpen() {
  const clock = deployment.marketClock;
  const enabled = live && !isZero(clock);
  const now = BigInt(Math.floor(Date.now() / 60_000) * 60); // minute-stable key
  return useReadContract({
    address: clock,
    abi: marketClockAbi,
    functionName: "isOpen",
    args: [now],
    chainId,
    query: { enabled, refetchInterval: 60_000 },
  });
}

/** Core per-vault reads used by cards and the detail page. */
export function useVaultCore(vault: Address) {
  const enabled = live && !isZero(vault);
  const c = { address: vault, abi: rotationVaultAbi, chainId } as const;
  const q = useReadContracts({
    allowFailure: true,
    contracts: [
      { ...c, functionName: "totalAssets" },
      { ...c, functionName: "totalSupply" },
      { ...c, functionName: "convertToAssets", args: [10n ** 12n] },
      { ...c, functionName: "allocation" },
      { ...c, functionName: "stockWeightBps" },
      { ...c, functionName: "stockCapBps" },
      { ...c, functionName: "mgmtFeeBps" },
      { ...c, functionName: "depositCap" },
      { ...c, functionName: "paused" },
      { ...c, functionName: "name" },
      { ...c, functionName: "symbol" },
    ],
    query: { enabled, refetchInterval: 30_000 },
  });
  const d = q.data ?? [];
  const r = <T,>(i: number) => d[i]?.result as T | undefined;
  return {
    enabled,
    isLoading: q.isLoading,
    error: q.error,
    totalAssets: r<bigint>(0),
    totalSupply: r<bigint>(1),
    sharePrice: r<bigint>(2),
    allocation: r<readonly [readonly Address[], readonly bigint[], readonly bigint[], bigint, bigint]>(3),
    stockWeightBps: r<bigint>(4),
    stockCapBps: r<number>(5),
    mgmtFeeBps: r<number>(6),
    depositCap: r<bigint>(7),
    paused: r<boolean>(8),
    name: r<string>(9),
    symbol: r<string>(10),
  };
}

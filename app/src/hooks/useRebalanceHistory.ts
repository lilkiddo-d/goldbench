"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AbiEvent, Address, Hash } from "viem";
import { usePublicClient } from "wagmi";
import { rotationVaultAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero } from "@/config/deployments";
import { LOG_PAGE_BLOCKS, LOG_SCAN_BLOCKS } from "@/config/env";

const EVENT_NAMES = [
  "RebalanceStarted",
  "ChunkExecuted",
  "RebalanceCompleted",
  "RebalanceCancelled",
  "RebalanceExpired",
  "Trade",
  "TradeFailed",
] as const;

const EVENTS = (rotationVaultAbi as readonly { type: string; name?: string }[]).filter(
  (x) => x.type === "event" && EVENT_NAMES.includes(x.name as (typeof EVENT_NAMES)[number]),
) as unknown as AbiEvent[];

export type SignalSnapshot = {
  riskOn: boolean;
  strongTrend: boolean;
  basketRatioLong: bigint;
  basketRatioShort: bigint;
  basketVolBps: bigint;
  goldRatioLong: bigint;
  goldVolBps: bigint;
  stockScaleBps: bigint;
  goldShareBps: bigint;
  historyDays: bigint;
  timestamp: bigint;
};

export type TradeRow = { tokenIn: Address; tokenOut: Address; amountIn: bigint; amountOut?: bigint; failed: boolean; tx: Hash };

export type RebalanceRow = {
  id: bigint;
  startTx?: Hash;
  startBlock?: bigint;
  signal?: SignalSnapshot;
  assets: readonly Address[];
  targetBps: readonly number[];
  navStart?: bigint;
  chunks: { chunk: number; total: number; navBefore: bigint; tx: Hash }[];
  trades: TradeRow[];
  status: "running" | "completed" | "cancelled" | "expired";
  navEnd?: bigint;
  stockValueEnd?: bigint;
  endTx?: Hash;
};

type RawLog = {
  eventName: string;
  args: Record<string, unknown>;
  transactionHash: Hash;
  blockNumber: bigint;
  logIndex: number;
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Scans vault events backwards from the chain head in ≤50k-block pages (the public RPC is rate-limited and
 * Robinhood Chain produces ~4 blocks/s). Each "load" covers LOG_SCAN_BLOCKS; `loadMore()` continues further back,
 * never past the deployment block. Failing pages are retried with backoff, then split in half.
 */
export function useRebalanceHistory(vault: Address) {
  const client = usePublicClient({ chainId: robinhoodChain.id });
  const enabled = !isZero(vault) && !deployment.placeholder;
  const [logs, setLogs] = useState<RawLog[]>([]);
  const [cursor, setCursor] = useState<bigint | null>(null); // next block to scan down from (inclusive)
  const [head, setHead] = useState<bigint | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState(0);
  const started = useRef(false);
  const floor = deployment.deployedAtBlock;

  const fetchRange = useCallback(
    async (from: bigint, to: bigint): Promise<RawLog[]> => {
      if (!client) return [];
      let attempt = 0;
      for (;;) {
        try {
          const res = await client.getLogs({ address: vault, events: EVENTS, fromBlock: from, toBlock: to, strict: false });
          return res as unknown as RawLog[];
        } catch (e) {
          attempt++;
          if (attempt <= 3) {
            await sleep(500 * 2 ** attempt);
            continue;
          }
          if (to - from > 5_000n) {
            const mid = from + (to - from) / 2n;
            const a = await fetchRange(from, mid);
            const b = await fetchRange(mid + 1n, to);
            return [...a, ...b];
          }
          throw e;
        }
      }
    },
    [client, vault],
  );

  const scan = useCallback(
    async (startAt: bigint | null) => {
      if (!client || !enabled) return;
      setLoading(true);
      setError(null);
      try {
        let top = startAt;
        if (top === null) {
          const latest = await client.getBlockNumber();
          setHead(latest);
          top = latest;
        }
        const stop = top - LOG_SCAN_BLOCKS + 1n > floor ? top - LOG_SCAN_BLOCKS + 1n : floor;
        const total = Number(top - stop + 1n);
        let to = top;
        while (to >= stop) {
          const from = to - LOG_PAGE_BLOCKS + 1n > stop ? to - LOG_PAGE_BLOCKS + 1n : stop;
          const page = await fetchRange(from, to);
          if (page.length) setLogs((prev) => [...prev, ...page]);
          setProgress(Math.min(1, Number(top - from + 1n) / Math.max(1, total)));
          setCursor(from - 1n);
          if (from === 0n) break;
          to = from - 1n;
        }
      } catch (e) {
        setError(e instanceof Error ? e.message.split("\n")[0] : String(e));
      } finally {
        setLoading(false);
      }
    },
    [client, enabled, fetchRange, floor],
  );

  useEffect(() => {
    if (!enabled || !client || started.current) return;
    started.current = true;
    void scan(null);
  }, [enabled, client, scan]);

  const done = cursor !== null && cursor < floor;
  const loadMore = useCallback(() => {
    if (loading || done || cursor === null) return;
    void scan(cursor);
  }, [loading, done, cursor, scan]);

  const rows = useMemo(() => groupLogs(logs), [logs]);
  const scannedBlocks = head !== null && cursor !== null ? head - cursor : 0n;

  return { rows, loading, error, done, loadMore, progress, scannedBlocks, enabled };
}

function groupLogs(logs: RawLog[]): RebalanceRow[] {
  const sorted = [...logs].sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
  );
  const map = new Map<string, RebalanceRow>();
  const get = (id: bigint) => {
    const k = id.toString();
    let r = map.get(k);
    if (!r) {
      r = { id, assets: [], targetBps: [], chunks: [], trades: [], status: "running" };
      map.set(k, r);
    }
    return r;
  };
  for (const l of sorted) {
    const a = l.args ?? {};
    const id = a.id as bigint | undefined;
    if (id === undefined) continue;
    const r = get(id);
    switch (l.eventName) {
      case "RebalanceStarted":
        r.startTx = l.transactionHash;
        r.startBlock = l.blockNumber;
        r.signal = a.signal as SignalSnapshot;
        r.assets = (a.assets as Address[]) ?? [];
        r.targetBps = ((a.targetBps as (number | bigint)[]) ?? []).map(Number);
        r.navStart = a.nav as bigint;
        break;
      case "ChunkExecuted":
        r.chunks.push({
          chunk: Number(a.chunk),
          total: Number(a.chunksTotal),
          navBefore: a.navBefore as bigint,
          tx: l.transactionHash,
        });
        break;
      case "Trade":
        r.trades.push({
          tokenIn: a.tokenIn as Address,
          tokenOut: a.tokenOut as Address,
          amountIn: a.amountIn as bigint,
          amountOut: a.amountOut as bigint,
          failed: false,
          tx: l.transactionHash,
        });
        break;
      case "TradeFailed":
        r.trades.push({
          tokenIn: a.tokenIn as Address,
          tokenOut: a.tokenOut as Address,
          amountIn: a.amountIn as bigint,
          failed: true,
          tx: l.transactionHash,
        });
        break;
      case "RebalanceCompleted":
        r.status = "completed";
        r.navEnd = a.nav as bigint;
        r.stockValueEnd = a.stockValue as bigint;
        r.endTx = l.transactionHash;
        break;
      case "RebalanceCancelled":
        r.status = "cancelled";
        r.endTx = l.transactionHash;
        break;
      case "RebalanceExpired":
        r.status = "expired";
        r.endTx = l.transactionHash;
        break;
    }
  }
  return [...map.values()].sort((a, b) => (a.id < b.id ? 1 : -1));
}

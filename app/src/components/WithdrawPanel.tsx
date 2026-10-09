"use client";

import { useMemo, useState } from "react";
import { erc20Abi, type Address } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { rotationVaultAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero, SHARE_DECIMALS, symbolOf, USDG_DECIMALS } from "@/config/deployments";
import { useTx } from "@/hooks/useTx";
import { vaultCallAbi } from "@/lib/abis";
import { fmtUnits, fmtUsd } from "@/lib/format";
import { parseAmount } from "./DepositPanel";
import { Card, Row, Stat, TxStatus } from "./ui";

const chainId = robinhoodChain.id;

/** User position + cash / in-kind exits. */
export function WithdrawPanel({ vault }: { vault: Address }) {
  const { address } = useAccount();
  const enabled = !deployment.placeholder && !isZero(vault);
  const [input, setInput] = useState("");
  const shares = parseAmount(input, SHARE_DECIMALS);
  const tx = useTx();
  const who = address ?? deployment.usdg;

  const base = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: vault, abi: rotationVaultAbi, functionName: "balanceOf", args: [who], chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "maxRedeem", args: [who], chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "previewRedeem", args: [shares ?? 0n], chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "totalSupply", chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "holdings", chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "asset", chainId },
    ],
    query: { enabled, refetchInterval: 20_000 },
  });
  const d = base.data ?? [];
  const balance = address ? (d[0]?.result as bigint | undefined) : undefined;
  const maxRedeem = address ? (d[1]?.result as bigint | undefined) : undefined;
  const preview = shares ? (d[2]?.result as bigint | undefined) : undefined;
  const supply = d[3]?.result as bigint | undefined;
  const holdings = (d[4]?.result as readonly Address[] | undefined) ?? [];
  const asset = (d[5]?.result as Address | undefined) ?? deployment.usdg;

  const tokens = useMemo(() => [asset, ...holdings], [asset, holdings]);
  const bal = useReadContracts({
    allowFailure: true,
    contracts: tokens.flatMap((t) => [
      { address: t, abi: erc20Abi, functionName: "balanceOf", args: [vault], chainId } as const,
      { address: t, abi: erc20Abi, functionName: "decimals", chainId } as const,
    ]),
    query: { enabled: enabled && tokens.length > 0, refetchInterval: 30_000 },
  });

  const position = useReadContracts({
    allowFailure: true,
    contracts: [{ address: vault, abi: rotationVaultAbi, functionName: "convertToAssets", args: [balance ?? 0n], chainId }],
    query: { enabled: enabled && balance !== undefined },
  });
  const value = balance !== undefined ? (position.data?.[0]?.result as bigint | undefined) : undefined;

  const inKind = useMemo(() => {
    if (!shares || !supply || supply === 0n) return [];
    return tokens
      .map((t, i) => {
        const vb = (bal.data?.[2 * i]?.result as bigint | undefined) ?? 0n;
        const dec = Number((bal.data?.[2 * i + 1]?.result as number | undefined) ?? 18);
        return { token: t, amount: (vb * shares) / supply, decimals: dec };
      })
      .filter((x) => x.amount > 0n);
  }, [shares, supply, tokens, bal.data]);

  const overBalance = shares !== undefined && balance !== undefined && shares > balance;
  const overCash = shares !== undefined && maxRedeem !== undefined && shares > maxRedeem;
  const valid = !!address && shares !== undefined && shares > 0n && !overBalance && !tx.busy;

  const setPct = (pct: bigint, cap?: bigint) => {
    const b = cap ?? balance;
    if (b === undefined) return;
    setInput(fmtUnits((b * pct) / 100n, SHARE_DECIMALS, SHARE_DECIMALS).replace(/,/g, ""));
  };

  const redeem = async () => {
    if (!shares || !address) return;
    if (await tx.run("Cash redeem", { address: vault, abi: vaultCallAbi, functionName: "redeem", args: [shares, address, address] })) setInput("");
  };
  const redeemInKind = async () => {
    if (!shares || !address) return;
    if (await tx.run("In-kind redeem", { address: vault, abi: vaultCallAbi, functionName: "redeemInKind", args: [shares, address, address] }))
      setInput("");
  };

  return (
    <Card title="Your position & withdraw">
      <div className="mb-4 grid grid-cols-2 gap-4">
        <Stat label="Shares" value={address ? fmtUnits(balance, SHARE_DECIMALS, 4) : "—"} />
        <Stat label="Value" value={address ? fmtUsd(value, USDG_DECIMALS) : "—"} sub="USDG at current NAV" />
      </div>

      <div className="flex gap-2">
        <input
          className="input"
          inputMode="decimal"
          placeholder="Shares to redeem"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          aria-label="Shares to redeem"
        />
      </div>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {[25n, 50n, 100n].map((p) => (
          <button key={p.toString()} type="button" className="btn btn-ghost px-2.5 py-1 text-xs" disabled={!balance} onClick={() => setPct(p)}>
            {p.toString()}%
          </button>
        ))}
        <button type="button" className="btn btn-ghost px-2.5 py-1 text-xs" disabled={!maxRedeem} onClick={() => setPct(100n, maxRedeem)}>
          Max cash
        </button>
      </div>

      <div className="mt-3 divide-y divide-ink-800">
        <Row label="Max cash redeem now" value={`${fmtUnits(maxRedeem, SHARE_DECIMALS, 4)} shares`} />
        <Row label="Cash you receive (est.)" value={preview !== undefined ? `${fmtUnits(preview, USDG_DECIMALS, 2)} USDG` : "—"} />
      </div>

      <div className="mt-4 grid grid-cols-2 gap-2">
        <button className="btn btn-gold" type="button" disabled={!valid || overCash} onClick={redeem}>
          Redeem for USDG
        </button>
        <button className="btn btn-ghost" type="button" disabled={!valid} onClick={redeemInKind}>
          Redeem in-kind
        </button>
      </div>
      {overBalance && <p className="mt-2 text-xs text-bad">More than your share balance.</p>}
      {!overBalance && overCash && (
        <p className="mt-2 text-xs text-down">
          Cash exits are limited to the vault&apos;s idle USDG. Use in-kind redemption for this size.
        </p>
      )}

      {inKind.length > 0 && (
        <div className="mt-4 rounded-lg border border-ink-700 bg-ink-900/60 p-3">
          <div className="mb-1 text-xs text-ink-400">In-kind: you would receive (pro-rata of vault balances)</div>
          {inKind.map((x) => (
            <Row key={x.token} label={symbolOf(x.token)} value={fmtUnits(x.amount, x.decimals, x.decimals === 6 ? 2 : 6)} />
          ))}
        </div>
      )}
      <p className="mt-3 text-xs text-ink-400">
        Cash redemptions use idle USDG and need fresh oracle prices. In-kind redemption hands you your slice of every
        token the vault holds; it needs no oracle and works even when the vault is paused.
      </p>
      <TxStatus state={tx.state} />
    </Card>
  );
}

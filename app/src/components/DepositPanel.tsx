"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { erc20Abi, parseUnits, type Address } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { rotationVaultAbi } from "@/abi/generated";
import { robinhoodChain } from "@/config/chain";
import { deployment, isZero, SHARE_DECIMALS, USDG_DECIMALS } from "@/config/deployments";
import { useDisclosure } from "@/hooks/useDisclosure";
import { useTx } from "@/hooks/useTx";
import { vaultCallAbi } from "@/lib/abis";
import { fmtUnits } from "@/lib/format";
import { Card, Row, TxStatus } from "./ui";

const chainId = robinhoodChain.id;

export function parseAmount(s: string, decimals: number): bigint | undefined {
  const t = s.trim().replace(/,/g, "");
  if (!t || !/^\d*\.?\d*$/.test(t) || t === ".") return undefined;
  try {
    return parseUnits(t, decimals);
  } catch {
    return undefined;
  }
}

export function DepositPanel({ vault, paused }: { vault: Address; paused?: boolean }) {
  const { address } = useAccount();
  const { accepted, setAccepted } = useDisclosure();
  const [input, setInput] = useState("");
  const amount = parseAmount(input, USDG_DECIMALS);
  const usdg = deployment.usdg;
  const enabled = !deployment.placeholder && !isZero(vault) && !isZero(usdg);
  const tx = useTx();

  // wallet-specific reads only run once a wallet is connected (no placeholder-address reads)
  const user = useReadContracts({
    allowFailure: true,
    contracts: address
      ? [
          { address: usdg, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId } as const,
          { address: usdg, abi: erc20Abi, functionName: "allowance", args: [address, vault], chainId } as const,
        ]
      : [],
    query: { enabled: enabled && !!address, refetchInterval: 20_000 },
  });
  const q = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: vault, abi: rotationVaultAbi, functionName: "maxDeposit", args: [address ?? vault], chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "previewDeposit", args: [amount ?? 0n], chainId },
      { address: vault, abi: rotationVaultAbi, functionName: "depositCap", chainId },
    ],
    query: { enabled, refetchInterval: 20_000 },
  });
  const u = user.data ?? [];
  const d = q.data ?? [];
  const balance = address ? (u[0]?.result as bigint | undefined) : undefined;
  const allowance = address ? (u[1]?.result as bigint | undefined) : undefined;
  const maxDeposit = d[0]?.result as bigint | undefined;
  const preview = amount ? (d[1]?.result as bigint | undefined) : undefined;
  const cap = d[2]?.result as bigint | undefined;

  const problem = useMemo(() => {
    if (!enabled) return "Vault not deployed yet.";
    if (paused) return "Vault is paused.";
    if (!address) return "Connect a wallet to deposit.";
    if (!accepted) return "Accept the risk disclosure first.";
    if (amount === undefined || amount === 0n) return null;
    if (balance !== undefined && amount > balance) return "Amount exceeds your USDG balance.";
    if (maxDeposit !== undefined && amount > maxDeposit) return "Amount exceeds the remaining deposit cap.";
    return null;
  }, [enabled, paused, address, accepted, amount, balance, maxDeposit]);

  const canAct = !problem && amount !== undefined && amount > 0n && !tx.busy;
  const needsApproval = allowance !== undefined && amount !== undefined && allowance < amount;

  const approve = () =>
    amount && tx.run("Approve USDG", { address: usdg, abi: erc20Abi, functionName: "approve", args: [vault, amount] });
  const deposit = async () => {
    if (!amount || !address) return;
    const ok = await tx.run("Deposit", { address: vault, abi: vaultCallAbi, functionName: "deposit", args: [amount, address] });
    if (ok) setInput("");
  };

  return (
    <Card title="Deposit USDG">
      <div className="flex gap-2">
        <input
          className="input"
          inputMode="decimal"
          placeholder="0.00"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          aria-label="Deposit amount in USDG"
        />
        <button
          className="btn btn-ghost"
          type="button"
          disabled={!balance}
          onClick={() => {
            if (balance === undefined) return;
            const m = maxDeposit !== undefined && maxDeposit < balance ? maxDeposit : balance;
            setInput(fmtUnits(m, USDG_DECIMALS, USDG_DECIMALS).replace(/,/g, ""));
          }}
        >
          Max
        </button>
      </div>

      <div className="mt-3 divide-y divide-ink-800">
        <Row label="Wallet balance" value={`${fmtUnits(balance, USDG_DECIMALS, 2)} USDG`} />
        <Row label="You receive (est.)" value={preview !== undefined ? `${fmtUnits(preview, SHARE_DECIMALS, 4)} shares` : "—"} />
        <Row label="Remaining capacity" value={`${fmtUnits(maxDeposit, USDG_DECIMALS, 0)} / ${fmtUnits(cap, USDG_DECIMALS, 0)} USDG`} />
      </div>

      <label className="mt-4 flex cursor-pointer items-start gap-2.5 text-xs text-ink-300">
        <input
          type="checkbox"
          className="mt-0.5 accent-[#d4a73a]"
          checked={accepted}
          onChange={(e) => setAccepted(e.target.checked)}
        />
        <span>
          I have read and understand the{" "}
          <Link href="/risk" className="text-gold-400 underline-offset-2 hover:underline">
            risk disclosure
          </Link>
          . This is not investment advice and I may lose money.
        </span>
      </label>

      <div className="mt-4 grid grid-cols-2 gap-2">
        <button className="btn btn-ghost" type="button" disabled={!canAct || !needsApproval} onClick={approve}>
          1 · Approve
        </button>
        <button className="btn btn-gold" type="button" disabled={!canAct || needsApproval || allowance === undefined} onClick={deposit}>
          2 · Deposit
        </button>
      </div>
      {problem && <p className="mt-3 text-xs text-ink-400">{problem}</p>}
      <p className="mt-3 text-xs text-ink-400">
        Deposits need fresh oracle prices: they revert while US markets are closed or a price looks off.
      </p>
      <TxStatus state={tx.state} />
    </Card>
  );
}

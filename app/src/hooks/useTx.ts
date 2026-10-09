"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useState } from "react";
import type { Abi, Address, Hash } from "viem";
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from "wagmi";
import { robinhoodChain } from "@/config/chain";
import { friendlyError } from "@/lib/errors";

export type TxCall = {
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
};

export type TxState = {
  status: "idle" | "simulating" | "signing" | "confirming" | "success" | "error";
  label?: string;
  hash?: Hash;
  error?: string;
};

/**
 * simulate → (switch chain) → sign → wait for receipt → refetch all reads.
 * Simulation first so custom-error reverts (StalePrice, PriceDeviation, …) are decoded before the wallet opens.
 */
export function useTx() {
  const { address, chainId } = useAccount();
  const publicClient = usePublicClient({ chainId: robinhoodChain.id });
  const { writeContractAsync } = useWriteContract();
  const { switchChainAsync } = useSwitchChain();
  const qc = useQueryClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  const run = useCallback(
    async (label: string, call: TxCall): Promise<boolean> => {
      if (!address || !publicClient) {
        setState({ status: "error", label, error: "Connect a wallet first." });
        return false;
      }
      try {
        if (chainId !== robinhoodChain.id) await switchChainAsync({ chainId: robinhoodChain.id });
        setState({ status: "simulating", label });
        const { request } = await publicClient.simulateContract({
          ...(call as { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] }),
          account: address,
        });
        setState({ status: "signing", label });
        const hash = await writeContractAsync(request as unknown as Parameters<typeof writeContractAsync>[0]);
        setState({ status: "confirming", label, hash });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("Transaction reverted on-chain.");
        setState({ status: "success", label, hash });
        await qc.invalidateQueries();
        return true;
      } catch (e) {
        setState((s) => ({ status: "error", label, hash: s.hash, error: friendlyError(e) }));
        return false;
      }
    },
    [address, chainId, publicClient, switchChainAsync, writeContractAsync, qc],
  );

  const busy = state.status === "simulating" || state.status === "signing" || state.status === "confirming";
  const reset = useCallback(() => setState({ status: "idle" }), []);
  return { run, state, busy, reset };
}

import type { Abi } from "viem";

type AbiError = Extract<Abi[number], { type: "error" }>;
import {
  chainlinkOracleAdapterAbi,
  priceHistoryAbi,
  projectTokenHooksAbi,
  rotationVaultAbi,
  signalEngineAbi,
} from "@/abi/generated";

export * from "@/abi/generated";

/** All custom errors a Goldbench call can bubble (vault + oracle + history + engine + hooks), deduplicated. */
export const errorAbi: Abi = (() => {
  const seen = new Set<string>();
  const out: AbiError[] = [];
  const all = [rotationVaultAbi, chainlinkOracleAdapterAbi, priceHistoryAbi, signalEngineAbi, projectTokenHooksAbi] as unknown as Abi[];
  for (const abi of all) {
    for (const item of abi) {
      if (item.type !== "error") continue;
      const sig = `${item.name}(${item.inputs.map((i) => i.type).join(",")})`;
      if (seen.has(sig)) continue;
      seen.add(sig);
      out.push(item);
    }
  }
  return out;
})();

/** Vault ABI extended with every error the vault can bubble, for simulate/write decoding. */
export const vaultCallAbi = [...rotationVaultAbi, ...(errorAbi as readonly AbiError[])] as unknown as typeof rotationVaultAbi;

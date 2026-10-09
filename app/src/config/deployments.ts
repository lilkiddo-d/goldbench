import { getAddress, zeroAddress, type Address } from "viem";
import { DEPLOYMENT_KEY } from "./env";
import d4663 from "./deployments.4663.json";
import d4663fork from "./deployments.4663-fork.json";

/**
 * Registry of every known deployment file. The deploy script (contracts/script/Deploy.s.sol) overwrites these JSONs;
 * the committed versions are placeholders (`"placeholder": true`, zero addresses) so the app builds before deployment.
 * To add a new deployment, drop `deployments.<key>.json` here and add one import line below.
 */
const registry: Record<string, unknown> = {
  "4663": d4663,
  "4663-fork": d4663fork,
};

const ADDRESS_KEYS = [
  "timelock",
  "marketClock",
  "oracleAdapter",
  "priceHistory",
  "signalEngine",
  "allocator",
  "dexAdapter",
  "complianceRegistry",
  "feeCollector",
  "projectTokenHooks",
  "vaultImplementation",
  "vaultFactory",
  "vaultSteady",
  "vaultBalanced",
  "vaultBold",
  "owner",
  "guardian",
  "keeper",
  "treasury",
  "usdg",
  "spy",
  "qqq",
  "gld",
  "sgov",
] as const;

export type AddressKey = (typeof ADDRESS_KEYS)[number];

export type Deployment = { [K in AddressKey]: Address } & {
  key: string;
  chainId: number;
  deployedAtBlock: bigint;
  placeholder: boolean;
  /** true when NEXT_PUBLIC_DEPLOYMENT named a file that is not in the registry */
  unknownKey: boolean;
};

function normalise(key: string, raw: unknown, unknownKey: boolean): Deployment {
  const r = (raw ?? {}) as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of ADDRESS_KEYS) {
    const v = typeof r[k] === "string" ? (r[k] as string) : zeroAddress;
    try {
      out[k] = getAddress(v);
    } catch {
      out[k] = zeroAddress;
    }
  }
  const d = out as { [K in AddressKey]: Address };
  return {
    ...d,
    key,
    chainId: typeof r.chainId === "number" ? r.chainId : 4663,
    deployedAtBlock: BigInt(typeof r.deployedAtBlock === "number" ? r.deployedAtBlock : 0),
    placeholder: r.placeholder === true || d.vaultSteady === zeroAddress,
    unknownKey,
  };
}

const known = DEPLOYMENT_KEY in registry;
export const deployment: Deployment = normalise(
  known ? DEPLOYMENT_KEY : "4663",
  registry[known ? DEPLOYMENT_KEY : "4663"],
  !known,
);

export const isZero = (a: Address | undefined) => !a || a.toLowerCase() === zeroAddress;

/** Lower-cased address → display symbol, for labelling holdings. */
export const symbolByAddress: Record<string, string> = Object.fromEntries(
  (
    [
      ["usdg", "USDG"],
      ["spy", "SPY"],
      ["qqq", "QQQ"],
      ["gld", "GLD"],
      ["sgov", "SGOV"],
    ] as const
  )
    .filter(([k]) => !isZero(deployment[k]))
    .map(([k, s]) => [deployment[k].toLowerCase(), s]),
);

export const symbolOf = (a: string) => symbolByAddress[a.toLowerCase()] ?? `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Decimals of known tokens (USDG 6, Stock Tokens 18). */
export const decimalsOf = (a: string) => (symbolByAddress[a.toLowerCase()] === "USDG" ? 6 : 18);

export const USDG_DECIMALS = 6;
export const SHARE_DECIMALS = 12;
export const ONE_SHARE = 10n ** 12n;

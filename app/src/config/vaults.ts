import type { Address } from "viem";
import { deployment } from "./deployments";

export type VaultSlug = "steady" | "balanced" | "bold";

export interface VaultMeta {
  slug: VaultSlug;
  name: string;
  tagline: string;
  /** Nominal stock cap (bps) — the on-chain stockCapBps() is authoritative and shown when available. */
  capBps: number;
  address: Address;
}

export const VAULTS: VaultMeta[] = [
  {
    slug: "steady",
    name: "Steady",
    tagline: "At most 40% in stocks. Gold and T-bills do most of the work.",
    capBps: 4000,
    address: deployment.vaultSteady,
  },
  {
    slug: "balanced",
    name: "Balanced",
    tagline: "Up to 70% in stocks when the trend is up.",
    capBps: 7000,
    address: deployment.vaultBalanced,
  },
  {
    slug: "bold",
    name: "Bold",
    tagline: "Up to 100% in stocks in a strong uptrend.",
    capBps: 10000,
    address: deployment.vaultBold,
  },
];

export const vaultBySlug = (slug: string) => VAULTS.find((v) => v.slug === slug);

export const MGMT_FEE_LABEL = "0.75% / yr";

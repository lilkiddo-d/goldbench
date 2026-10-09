import { isAddress, getAddress, type Address } from "viem";

// NOTE: each NEXT_PUBLIC_* var must be referenced literally so Next.js can inline it at build time.

export const RPC_URL = (process.env.NEXT_PUBLIC_RPC_URL || "").trim() || "https://rpc.mainnet.chain.robinhood.com";

export const DEPLOYMENT_KEY = (process.env.NEXT_PUBLIC_DEPLOYMENT || "").trim() || "4663";

export const WC_PROJECT_ID = (process.env.NEXT_PUBLIC_WC_PROJECT_ID || "").trim();

const rawToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "").trim();
/** $GBEN token address, or undefined when token features are disabled. */
export const PROJECT_TOKEN: Address | undefined = isAddress(rawToken) ? getAddress(rawToken) : undefined;
export const TOKEN_ENABLED = PROJECT_TOKEN !== undefined;

const scan = Number(process.env.NEXT_PUBLIC_LOG_SCAN_BLOCKS || "");
/** Blocks scanned per "load" of rebalance history (paged backwards in LOG_PAGE_BLOCKS steps). */
export const LOG_SCAN_BLOCKS = BigInt(Number.isFinite(scan) && scan > 0 ? Math.floor(scan) : 2_000_000);
export const LOG_PAGE_BLOCKS = 50_000n;

export const EXPLORER_URL = "https://robinhoodchain.blockscout.com";

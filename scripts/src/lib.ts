import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, defineChain, http, parseAbi, type Address } from "viem";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const CONTRACTS = join(ROOT, "contracts");

export const env = {
  rpcUrl: process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com",
  deploymentFile: process.env.GOLDBENCH_DEPLOYMENT ?? join(ROOT, "deployments", "4663.json"),
  account: process.env.KEEPER_ACCOUNT ?? "goldbench-keeper",
  passwordFile: process.env.KEEPER_PASSWORD_FILE,
  /** Override the signer flags entirely, e.g. "--unlocked --sender 0x..." against a local anvil fork. */
  signerArgs: process.env.KEEPER_SIGNER_ARGS,
  pollSeconds: Number(process.env.POLL_SECONDS ?? 60),
  /** Earliest New York minute-of-day to *start* a rebalance (default 10:00, avoids the opening auction). */
  rebalanceAfterMinute: Number(process.env.REBALANCE_AFTER_MINUTE ?? 10 * 60),
  dryRun: process.env.DRY_RUN === "1",
};

export type Deployment = Record<string, Address | number>;

export function loadDeployment(): Deployment {
  return JSON.parse(readFileSync(env.deploymentFile, "utf8"));
}

export const chain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [env.rpcUrl] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

export const client = createPublicClient({
  chain,
  transport: http(env.rpcUrl, { retryCount: 5, retryDelay: 1500, timeout: Number(process.env.RPC_TIMEOUT_MS ?? 30_000) }),
});

export const abi = {
  clock: parseAbi([
    "function isOpen(uint256) view returns (bool)",
    "function etDay(uint256) view returns (uint256)",
    "function lastCompletedSession(uint256) view returns (uint256)",
    "function closeTimestamp(uint256) view returns (uint256)",
    "function isTradingDay(uint256) view returns (bool)",
  ]),
  history: parseAbi([
    "function assets() view returns (address[])",
    "function lastDay(address) view returns (uint256)",
    "function count(address) view returns (uint256)",
    "function maxRecordDelay() view returns (uint32)",
    "function seedingClosed(address) view returns (bool)",
    "function paused() view returns (bool)",
  ]),
  engine: parseAbi([
    "function computeSignal() view returns ((bool riskOn,bool strongTrend,uint256 basketRatioLong,uint256 basketRatioShort,uint256 basketVolBps,uint256 goldRatioLong,uint256 goldVolBps,uint256 stockScaleBps,uint256 goldShareBps,uint256 historyDays,uint256 timestamp))",
  ]),
  vault: parseAbi([
    "function name() view returns (string)",
    "function plan() view returns (bool active, uint8 chunksDone, uint8 chunksTotal, uint64 lastChunkAt, uint64 expiresAt)",
    "function chunkInterval() view returns (uint32)",
    "function rebalanceInterval() view returns (uint32)",
    "function lastRebalanceStart() view returns (uint64)",
    "function paused() view returns (bool)",
    "function totalAssets() view returns (uint256)",
    "function stockWeightBps() view returns (uint256)",
  ]),
};

export const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

/** Run a keeper action through `forge script script/Keeper.s.sol` — signing happens inside Foundry (keystore). */
export function forgeKeeper(sig: string, args: string[] = []): Promise<number> {
  const signer = env.signerArgs
    ? env.signerArgs.split(/\s+/).filter(Boolean)
    : [
        "--keystore",
        join(homedir(), ".foundry", "keystores", env.account),
        ...(env.passwordFile ? ["--password-file", env.passwordFile] : []),
      ];
  const cmd = [
    "script",
    "script/Keeper.s.sol",
    "--sig",
    sig,
    ...args,
    "--rpc-url",
    env.rpcUrl,
    ...(env.dryRun ? [] : ["--broadcast"]),
    // try/catch swaps make eth_estimateGas under-estimate (63/64 rule); give every keeper tx ample headroom
    "--gas-estimate-multiplier",
    process.env.GAS_ESTIMATE_MULTIPLIER ?? "300",
    ...signer,
  ];
  log("forge", sig, args.join(" "), env.dryRun ? "(dry run)" : "");
  return new Promise((res) => {
    const p = spawn("forge", cmd, {
      cwd: CONTRACTS,
      stdio: "inherit",
      env: { ...process.env, GOLDBENCH_DEPLOYMENT: env.deploymentFile },
      shell: process.platform === "win32",
    });
    p.on("exit", (code) => res(code ?? 1));
  });
}

export async function nowTs(): Promise<bigint> {
  const b = await client.getBlock();
  return b.timestamp;
}

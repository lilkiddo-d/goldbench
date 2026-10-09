/**
 * One-time bootstrap of PriceHistory from the oracle's own round history (wraps script/SeedHistory.s.sol).
 * Run once right after deployment, on a weekday (the seeding sanity check needs a fresh live price), and
 * BEFORE the keeper records its first daily close (which permanently closes seeding).
 *   KEEPER_PASSWORD_FILE=... pnpm --filter scripts seed
 */
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { CONTRACTS, env, log } from "./lib.js";

const signer = env.signerArgs
  ? env.signerArgs.split(/\s+/).filter(Boolean)
  : [
      "--keystore",
      join(homedir(), ".foundry", "keystores", env.account),
      ...(env.passwordFile ? ["--password-file", env.passwordFile] : []),
    ];

const args = [
  "script",
  "script/SeedHistory.s.sol",
  "--rpc-url",
  env.rpcUrl,
  ...(env.dryRun ? [] : ["--broadcast", "--slow"]),
  ...signer,
];
log("forge", args.join(" "));
const p = spawn("forge", args, {
  cwd: CONTRACTS,
  stdio: "inherit",
  env: { ...process.env, GOLDBENCH_DEPLOYMENT: env.deploymentFile },
  shell: process.platform === "win32",
});
p.on("exit", (code) => process.exit(code ?? 1));

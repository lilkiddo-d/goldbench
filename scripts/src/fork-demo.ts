/**
 * LOCAL ANVIL FORK DEMO (never point this at mainnet — it refuses unless the RPC is localhost).
 * After `Deploy.s.sol` + `SeedHistory.s.sol` ran against the fork, this:
 *   1. pins every Chainlink feed to its CURRENT answer with a fresh timestamp (simulated heartbeat),
 *   2. moves fork time into the next US session (11:00 New York),
 *   3. funds a demo wallet with USDG (impersonating a Uniswap pool that holds USDG) and deposits into all 3 vaults,
 *   4. runs a full weekly rebalance (start + 4 TWAP chunks) on every vault as the keeper,
 * so the frontend has real allocations, signals and rebalance history to display.
 *   RPC_URL=http://127.0.0.1:38545 GOLDBENCH_DEPLOYMENT=../deployments/4663-fork.json DEMO_USER=0x... pnpm --filter scripts exec tsx src/fork-demo.ts
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  createTestClient,
  createWalletClient,
  encodeAbiParameters,
  erc20Abi,
  http,
  parseAbi,
  parseUnits,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { abi, chain, client, CONTRACTS, env, loadDeployment, log } from "./lib.js";

if (!/127\.0\.0\.1|localhost/.test(env.rpcUrl)) throw new Error("fork-demo only runs against a local anvil fork");

const FEEDS: Address[] = [
  "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2", // USDG/USD
  "0x319724394D3A0e3669269846abE664Cd621f9f6A", // SPY
  "0x80901d846d5D7B030F26B480776EE3b29374C2ae", // QQQ
  "0x470A51258068043bd43dC0a56245625C9fE86eB0", // GLD
  "0xa0DF4ee0fFf975306345875E3548Fcc519577A11", // SGOV
];
const USDG_POOL: Address = "0xD60A5d14dB690B7Afad71F76B108071D7175597d"; // QQQ/USDG 0.05 % pool (holds USDG)
const feedAbi = parseAbi([
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
  "function decimals() view returns (uint8)",
]);
const vaultWrite = parseAbi([
  "function deposit(uint256,address) returns (uint256)",
  "function startRebalance()",
  "function executeChunk(uint256)",
  "function chunkCount() view returns (uint8)",
  "function chunkInterval() view returns (uint32)",
]);

const slow = http(env.rpcUrl, { timeout: 600_000 });
const test = createTestClient({ chain, mode: "anvil", transport: slow });
const wallet = createWalletClient({ chain, transport: slow });
const d = loadDeployment();
const demoUser = (process.env.DEMO_USER ?? "0x70997970C51812dc3A010C7d01b50e0d17dc79C8") as Address;
const keeper = d.keeper as Address;

const slot = (n: number) => toHex(n, { size: 32 });
const word = (v: bigint) => encodeAbiParameters([{ type: "uint256" }], [v]) as Hex;

async function pinFeeds(ts: bigint) {
  const art = JSON.parse(readFileSync(join(CONTRACTS, "out/PinnedFeed.sol/PinnedFeed.json"), "utf8"));
  for (const f of FEEDS) {
    const code = await client.getCode({ address: f });
    let answer: bigint, roundId: bigint, dec: number;
    if (code === art.deployedBytecode.object) {
      answer = BigInt(await client.getStorageAt({ address: f, slot: slot(0) }) ?? 0);
      roundId = BigInt(await client.getStorageAt({ address: f, slot: slot(2) }) ?? 0);
      dec = Number(BigInt(await client.getStorageAt({ address: f, slot: slot(3) }) ?? 0));
    } else {
      const r = await client.readContract({ address: f, abi: feedAbi, functionName: "latestRoundData" });
      dec = await client.readContract({ address: f, abi: feedAbi, functionName: "decimals" });
      [roundId, answer] = [r[0], r[1]];
      await test.setCode({ address: f, bytecode: art.deployedBytecode.object });
    }
    await test.setStorageAt({ address: f, index: 0, value: word(answer) });
    await test.setStorageAt({ address: f, index: 1, value: word(ts) });
    await test.setStorageAt({ address: f, index: 2, value: word(roundId) });
    await test.setStorageAt({ address: f, index: 3, value: word(BigInt(dec)) });
  }
}

async function setTime(ts: bigint) {
  await test.setNextBlockTimestamp({ timestamp: ts });
  await test.mine({ blocks: 1 });
  await pinFeeds(ts);
}

async function send(from: Address, address: Address, functionName: string, args: unknown[], abiDef: readonly unknown[] = vaultWrite) {
  await test.impersonateAccount({ address: from });
  await test.setBalance({ address: from, value: parseUnits("10", 18) });
  const hash = await wallet.writeContract({ account: from, chain, address, abi: abiDef as never, functionName: functionName as never, args: args as never, gas: 8_000_000n });
  const rc = await client.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${functionName} reverted`);
  return rc;
}

async function main() {
  const clock = d.marketClock as Address;
  let now = (await client.getBlock()).timestamp;
  let day = await client.readContract({ address: clock, abi: abi.clock, functionName: "etDay", args: [now] });
  const close = await client.readContract({ address: clock, abi: abi.clock, functionName: "closeTimestamp", args: [day] });
  if (now >= close - 150n * 60n) day += 1n; // need ~2.5h of session left for 4 chunks
  while (!(await client.readContract({ address: clock, abi: abi.clock, functionName: "isTradingDay", args: [day] }))) day += 1n;
  const t11 = (await client.readContract({ address: clock, abi: abi.clock, functionName: "closeTimestamp", args: [day] })) - 5n * 3600n;
  const chainNow = (await client.getBlock()).timestamp;
  const start = chainNow > t11 ? chainNow + 5n : t11;
  log("fork time ->", new Date(Number(start) * 1000).toISOString());
  await setTime(start);

  // fund demo user with USDG and some ETH for gas
  await test.setBalance({ address: demoUser, value: parseUnits("10", 18) });
  await test.setBalance({ address: USDG_POOL, value: parseUnits("1", 18) });
  const have = await client.readContract({ address: d.usdg as Address, abi: erc20Abi, functionName: "balanceOf", args: [demoUser] });
  if (have < parseUnits("15000", 6)) {
    await send(USDG_POOL, d.usdg as Address, "transfer", [demoUser, parseUnits("30000", 6)], erc20Abi);
  }
  for (const k of ["vaultSteady", "vaultBalanced", "vaultBold"] as const) {
    const v = d[k] as Address;
    const held = await client.readContract({ address: v, abi: erc20Abi, functionName: "balanceOf", args: [demoUser] });
    if (held > 0n) continue; // resumable
    await send(demoUser, d.usdg as Address, "approve", [v, parseUnits("10000", 6)], erc20Abi);
    await send(demoUser, v, "deposit", [parseUnits("5000", 6), demoUser]);
    log(`deposited 5,000 USDG into ${k}`);
  }

  await test.setBalance({ address: keeper, value: parseUnits("10", 18) });
  now = start;
  for (const k of ["vaultSteady", "vaultBalanced", "vaultBold"] as const) {
    const v = d[k] as Address;
    let plan = await client.readContract({ address: v, abi: abi.vault, functionName: "plan" });
    if (!plan[0]) {
      const last = await client.readContract({ address: v, abi: abi.vault, functionName: "lastRebalanceStart" });
      if (last !== 0n) continue; // already rebalanced this week
      await send(keeper, v, "startRebalance", []);
      plan = await client.readContract({ address: v, abi: abi.vault, functionName: "plan" });
    }
    const gap = BigInt(await client.readContract({ address: v, abi: vaultWrite, functionName: "chunkInterval" }));
    for (let i = plan[1]; i < plan[2]; i++) {
      const chainNow = (await client.getBlock()).timestamp;
      const lastChunk = (await client.readContract({ address: v, abi: abi.vault, functionName: "plan" }))[3];
      if (lastChunk !== 0n && chainNow < lastChunk + gap) {
        now = lastChunk + gap;
        await setTime(now);
      }
      const t = (await client.getBlock()).timestamp;
      await send(keeper, v, "executeChunk", [t + 3600n]);
    }
    const w = await client.readContract({ address: v, abi: abi.vault, functionName: "stockWeightBps" });
    log(`${k}: rebalanced, stock weight ${Number(w) / 100}%`);
    now = (await client.getBlock()).timestamp + 60n;
    await setTime(now);
  }
  log("demo state ready — demo user", demoUser, "holds shares in all three vaults");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

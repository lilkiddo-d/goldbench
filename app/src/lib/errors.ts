import { BaseError, ContractFunctionRevertedError, decodeErrorResult, UserRejectedRequestError, type Hex } from "viem";
import { errorAbi } from "./abis";
import { symbolOf } from "@/config/deployments";

export type DecodedRevert = { name: string; args: readonly unknown[] };

const fmtArg = (a: unknown) => (typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a) ? symbolOf(a) : String(a));

const FRIENDLY: Record<string, (args: readonly unknown[]) => string> = {
  StalePrice: (a) =>
    `Oracle price for ${fmtArg(a[0])} is stale. Deposits and cash withdrawals pause while US markets are closed (e.g. weekends); in-kind redemption is always available.`,
  PriceDeviation: (a) =>
    `Live price of ${fmtArg(a[0])} deviates too far from its last recorded close, so the safety check blocked this. Try again later or use in-kind redemption.`,
  Depeg: () => "USDG is trading away from $1. Deposits and cash withdrawals are paused by the depeg guard.",
  OraclePausedByIssuer: (a) => `The token issuer has paused the oracle for ${fmtArg(a[0])}.`,
  InvalidPrice: (a) => `Oracle returned an invalid price for ${fmtArg(a[0])}.`,
  UnsupportedAsset: (a) => `No oracle feed configured for ${fmtArg(a[0])}.`,
  SequencerDown: () => "The chain sequencer is reported down.",
  SequencerGracePeriod: () => "Sequencer recently restarted; waiting for the grace period.",
  NotCompliant: () => "This address is not allowed to perform this action (compliance registry).",
  EnforcedPause: () => "The vault is paused by the guardian. In-kind redemption remains available.",
  ERC4626ExceededMaxDeposit: () => "Amount exceeds the vault's remaining deposit cap.",
  ERC4626ExceededMaxRedeem: () =>
    "Amount exceeds what can be redeemed in cash right now (limited to idle USDG). Use in-kind redemption for larger exits.",
  ERC4626ExceededMaxWithdraw: () => "Amount exceeds the cash available for withdrawal. Use in-kind redemption.",
  ERC20InsufficientAllowance: () => "Allowance too low; approve first.",
  ERC20InsufficientBalance: () => "Insufficient token balance.",
  ZeroShares: () => "Amount is zero.",
  ZeroAmount: () => "Amount is zero.",
  InsufficientHistory: (a) => `Signal warming up: ${a[0]}/${a[1]} sessions of price history.`,
  StakeLocked: (a) => `Stake is locked until ${new Date(Number(a[0]) * 1000).toLocaleString()} (you voted on an open proposal).`,
  BelowThreshold: () => "Your stake is below the proposal threshold.",
  VotingClosed: () => "Voting on this proposal has closed.",
  AlreadyVoted: () => "You already voted on this proposal.",
  VotingOpen: () => "Voting is still open.",
  ProposalFailed: () => "Proposal did not pass (needs more votes for than against, and quorum).",
  AlreadyQueued: () => "Proposal already queued.",
  InsufficientStake: () => "Insufficient stake.",
  NoStakers: () => "No stakers.",
  UnknownVault: () => "Vault is not registered for rebates.",
  OutOfBounds: (a) => `Value ${a[0]} is outside the allowed bounds [${a[1]}, ${a[2]}].`,
  InconsistentParams: () => "Value would make the signal parameters inconsistent (e.g. short MA >= long MA).",
  UnknownParam: () => "Unknown parameter id.",
  TokenNotSet: () => "The project token is not live yet.",
};

function tryDecode(data: unknown): DecodedRevert | undefined {
  if (typeof data !== "string" || !data.startsWith("0x") || data.length < 10) return undefined;
  try {
    const d = decodeErrorResult({ abi: errorAbi, data: data as Hex });
    return { name: d.errorName, args: (d.args ?? []) as readonly unknown[] };
  } catch {
    return undefined;
  }
}

export function decodeRevert(err: unknown): DecodedRevert | undefined {
  if (!(err instanceof BaseError)) return undefined;
  const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (revert instanceof ContractFunctionRevertedError) {
    if (revert.data?.errorName) return { name: revert.data.errorName, args: revert.data.args ?? [] };
    const raw = tryDecode((revert as unknown as { raw?: Hex }).raw);
    if (raw) return raw;
    if (revert.reason) return { name: revert.reason, args: [] };
  }
  // Raw revert data elsewhere in the cause chain (e.g. an RPC error carrying `data`).
  let found: DecodedRevert | undefined;
  err.walk((e) => {
    const d = tryDecode((e as { data?: unknown }).data);
    if (d) found = d;
    return !!d;
  });
  return found;
}

/** Human-readable message for any wagmi/viem error, decoding Goldbench custom errors. */
export function friendlyError(err: unknown): string {
  if (!err) return "";
  if (err instanceof BaseError && err.walk((e) => e instanceof UserRejectedRequestError)) {
    return "Transaction rejected in wallet.";
  }
  const d = decodeRevert(err);
  if (d) {
    const f = FRIENDLY[d.name];
    return f ? f(d.args) : `Reverted: ${d.name}(${d.args.map(fmtArg).join(", ")})`;
  }
  if (err instanceof BaseError) return err.shortMessage || err.message;
  if (err instanceof Error) return err.message;
  return String(err);
}

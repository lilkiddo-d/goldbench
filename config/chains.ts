/**
 * Goldbench — canonical chain configuration.
 *
 * EVERY address in this file was copied from an official source (linked inline) and
 * re-checked on-chain against https://rpc.mainnet.chain.robinhood.com on 2026-10-08
 * (eth_chainId = 0x1237 = 4663; decimals()/symbol() calls succeed on every token).
 * Never add an address here without a source link.
 *
 * Sources
 *  [RH-NET]   https://docs.robinhood.com/chain/deploy-smart-contracts/  (chain id, RPC, explorer, Blockscout verification)
 *  [RH-TOK]   https://docs.robinhood.com/chain/contracts/                (WETH, USDG; stock-token table is generated from the on-chain registry)
 *  [RH-API]   https://api.robinhood.com/rhj/assets                       (official asset registry API, documented at https://docs.robinhood.com/chain/stock-token-apis/)
 *  [RH-PROTO] https://docs.robinhood.com/chain/protocol-contracts/       (bridge / multicall / Permit2)
 *  [RH-ORA]   https://docs.robinhood.com/chain/oracles-and-price-feeds/  (Chainlink usage, oraclePaused(), uiMultiplier())
 *  [CL-FEEDS] https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *             raw JSON: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
 *  [CL-SEQ]   https://docs.chain.link/data-feeds/l2-sequencer-feeds      (NO Robinhood Chain entry as of 2026-10-08)
 *  [UNI-V3]   https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 *  [UNI-V4]   https://developers.uniswap.org/docs/protocols/v4/deployments
 */

export type Address = `0x${string}`;

export interface FeedInfo {
  proxy: Address;
  decimals: number;
  heartbeatSec: number;
  deviationPct: number;
  marketHours: "us_equities_24/5" | "Crypto";
  /** Chainlink feed risk category from [CL-FEEDS] */
  category: string;
  source: string;
}

export interface AssetInfo {
  symbol: string;
  name: string;
  address: Address;
  decimals: number;
  role: "base" | "stock" | "gold" | "tbill" | "commodity" | "bond";
  issuer: string;
  feed?: FeedInfo;
  source: string;
}

export const robinhoodMainnet = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, // [RH-NET] "uses ETH as its native gas token"
  rpcUrls: {
    public: "https://rpc.mainnet.chain.robinhood.com", // [RH-NET] rate-limited; use Alchemy for production
  },
  explorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com",
    apiUrl: "https://robinhoodchain.blockscout.com/api/",
  },
  // [RH-NET] `forge verify-contract ... --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`
  verification: { verifier: "blockscout", verifierUrl: "https://robinhoodchain.blockscout.com/api/" },
  testnet: {
    id: 46630,
    rpc: "https://rpc.testnet.chain.robinhood.com",
    explorer: "https://explorer.testnet.chain.robinhood.com",
  },
  sequencing: "first-come-first-served (no priority-fee reordering) — [RH-NET] About page",
} as const;

const feed = (
  proxy: Address,
  marketHours: FeedInfo["marketHours"],
  category: string,
): FeedInfo => ({
  proxy,
  decimals: 8,
  heartbeatSec: 86400,
  deviationPct: 0.5,
  marketHours,
  category,
  source: "[CL-FEEDS]",
});

const RHJ = "Robinhood Assets (Jersey) Limited (RHJ) — Stock Token issuer, see https://docs.robinhood.com/chain/stock-tokens/";

/** Assets Goldbench actually uses (all verified on-chain). */
export const assets = {
  USDG: {
    symbol: "USDG",
    name: "Global Dollar (Paxos)",
    address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    decimals: 6,
    role: "base",
    issuer: "Paxos — USD-backed stablecoin, redeemable 1:1 through Paxos (https://globaldollar.com/)",
    feed: feed("0x61B7e5650328764B076A108EFF5fa7282a1B9aD2", "Crypto", "medium"),
    source: "[RH-TOK]",
  },
  SPY: {
    symbol: "SPY",
    name: "SPDR S&P 500 ETF Trust • Robinhood Token",
    address: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C",
    decimals: 18,
    role: "stock",
    issuer: RHJ,
    feed: feed("0x319724394D3A0e3669269846abE664Cd621f9f6A", "us_equities_24/5", "custom"),
    source: "[RH-API]",
  },
  QQQ: {
    symbol: "QQQ",
    name: "Invesco QQQ • Robinhood Token",
    address: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68",
    decimals: 18,
    role: "stock",
    issuer: RHJ,
    feed: feed("0x80901d846d5D7B030F26B480776EE3b29374C2ae", "us_equities_24/5", "custom"),
    source: "[RH-API]",
  },
  GLD: {
    symbol: "GLD",
    name: "SPDR Gold Trust • Robinhood Token",
    address: "0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e",
    decimals: 18,
    role: "gold",
    issuer:
      RHJ +
      ". Underlying: SPDR Gold Trust (World Gold Trust Services) — physically backed by LBMA gold bars held by HSBC Bank plc (custodian). Token holders have NO direct claim on bullion.",
    // NOTE: Chainlink lists this feed as category "new", attributeType "dex_state_price", 24/7 hours.
    feed: feed("0x470A51258068043bd43dC0a56245625C9fE86eB0", "Crypto", "new"),
    source: "[RH-API]",
  },
  SGOV: {
    symbol: "SGOV",
    name: "iShares 0-3 Month Treasury Bond • Robinhood Token",
    address: "0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5",
    decimals: 18,
    role: "tbill",
    issuer: RHJ + ". Underlying: iShares 0-3 Month Treasury Bond ETF (BlackRock) holding US T-bills.",
    feed: feed("0xa0DF4ee0fFf975306345875E3548Fcc519577A11", "us_equities_24/5", "unlisted"),
    source: "[RH-API]",
  },
} as const satisfies Record<string, AssetInfo>;

/** Real on-chain tokens that exist but are NOT used (no Chainlink feed or out of scope). */
export const knownButUnused = {
  VTI: { address: "0x0594134DF3f171a354D9C85eBD65b7A6148F6D09", reason: "no Chainlink feed on Robinhood Chain", source: "[RH-API]" },
  SHY: { address: "0xBE274710Bf3d9567e1B290eF6a5F9f90ca016FD8", reason: "1-3y duration (not T-bill); no Chainlink feed", source: "[RH-API]" },
  BND: { address: "0x2F62fC9fAbb470C690f141c28340eD832bB27020", reason: "aggregate bond, no feed", source: "[RH-API]" },
  SLV: { address: "0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f", feed: "0x209b73908e92Ae021826eD79609845451Ecba2ce", reason: "silver — candidate commodity sleeve, not in v1", source: "[RH-API] / [CL-FEEDS]" },
  USO: { address: "0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344", feed: "0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c", reason: "oil futures ETF (contango drag) — excluded", source: "[RH-API] / [CL-FEEDS]" },
  WETH: { address: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", feed: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9", reason: "not a vault asset", source: "[RH-TOK] / [CL-FEEDS]" },
  USDC_USD_FEED: { address: "0x9e6f4605992a899eE2999999F3Ec80C41F452546", reason: "feed exists, but no canonical USDC token is listed in [RH-TOK]", source: "[CL-FEEDS]" },
} as const;

/** Gaps — things the spec wanted that do NOT exist on Robinhood Chain as of 2026-10-08. */
export const gaps = {
  PAXG_XAUT: "No canonical PAXG/XAUT deployment listed in [RH-TOK] or Chainlink feed list. Gold exposure uses the GLD Stock Token. OracleAdapter/asset list are swappable to add a bridged gold token later.",
  SEQUENCER_UPTIME_FEED: "Chainlink lists no L2 sequencer uptime feed for Robinhood Chain ([CL-SEQ]). OracleAdapter supports one (address(0) = disabled).",
  NATIVE_TBILL_TOKEN: "No tokenized T-bill fund (BUIDL/USTB/etc.) listed; SGOV Stock Token is used as the T-bill sleeve.",
} as const;

export const protocol = {
  uniswapV3: {
    factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
    swapRouter02: "0xcaf681a66d020601342297493863e78c959e5cb2",
    quoterV2: "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7",
    source: "[UNI-V3]",
  },
  uniswapV4: {
    poolManager: "0x8366a39cc670b4001a1121b8f6a443a643e40951",
    universalRouter: "0x8876789976decbfcbbbe364623c63652db8c0904",
    source: "[UNI-V4]",
  },
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", // [RH-PROTO]
  multicall: "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1", // [RH-PROTO] L2 Multicall
  sequencerUptimeFeed: "0x0000000000000000000000000000000000000000", // [CL-SEQ] none published
} as const;

# Asset research — what exists on Robinhood Chain (as of 2026-10-08)

Sources: [token contracts](https://docs.robinhood.com/chain/contracts/), [asset registry API](https://api.robinhood.com/rhj/assets) (documented at [Stock Token APIs](https://docs.robinhood.com/chain/stock-token-apis/)), [Stock Tokens](https://docs.robinhood.com/chain/stock-tokens/), [Chainlink Robinhood feeds](https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json), [Uniswap v3 deployments](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments). Every address was re-read on-chain (decimals, symbol, pool balances).

## Used by Goldbench

| Role | Token | Address | Chainlink feed | Deepest USDG pool (2026-10-08) |
|---|---|---|---|---|
| Base | USDG (Paxos Global Dollar, 6 dec) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `0x61B7…9aD2` (crypto, 24/7) | — |
| Stocks | SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | `0x3197…f6A` (24/5) | 0.05% · ~$198k USDG + 79 SPY |
| Stocks | QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | `0x8090…2ae` (24/5) | 0.05% · ~$626k USDG + 692 QQQ |
| Gold | GLD (SPDR Gold Trust) | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` | `0x470A…6eB0` (24/7, *dex_state_price*, category "new") | 0.3% · ~$438k USDG + 5,404 GLD |
| T-bills | SGOV (iShares 0–3M Treasury) | `0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5` | `0xa0DF…7A11` (24/5) | 0.3% · ~$1.29M USDG + 2,902 SGOV |

### Issuer and redemption rules
**USDG** — issued by Paxos; USD-backed stablecoin redeemable 1:1 through Paxos by eligible customers. Risk: issuer/reserve, depeg (vault strict paths reject prices outside ±3%).

**Stock Tokens (SPY, QQQ, GLD, SGOV)** — per the issuer:
- Issuer: **Robinhood Assets (Jersey) Limited (RHJ)**, Jersey private company no. 162428; RHJ is also the tokenizer.
- Legal form: **tokenised debt securities** providing economic exposure only — **no legal or beneficial rights** in, or against the issuer of, the underlying securities.
- Primary market: only **Authorised Participants** (at issuance only **BBVI**) may subscribe/redeem with RHJ after KYB; mint/burn window Mon 02:00 – Sat 02:00 CET. End users trade on-chain only.
- Corporate actions: dividends/splits via an on-chain multiplier (`uiMultiplier()`, ERC-8056); Chainlink prices already include it. `oraclePaused()` is set while a corporate action is processed.
- Distribution: **not registered under the U.S. Securities Act; may not be offered or sold to U.S. persons**; restricted in other jurisdictions incl. Canada, UK, Switzerland (full list in the prospectus at docs.robinhood.com/rhj).
- **GLD**: underlying SPDR Gold Trust holds LBMA gold bars with HSBC Bank plc as custodian (sponsor World Gold Trust Services). The token cannot be redeemed for metal. Its Chainlink feed is newer (rounds start 2026-09-19) and is a DEX-state-derived price — treated as the highest-risk feed (clamp + median + deviation checks; gold only steers the risk-off split).
- **SGOV**: underlying iShares 0–3 Month Treasury Bond ETF (BlackRock), short T-bills; total-return via the multiplier.

## Exists but not used
| Token | Address | Why not |
|---|---|---|
| SLV (silver) | `0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f` | Has feed; out of scope for v1 (second commodity, no model) |
| USO (oil) | `0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344` | Futures roll drag |
| VTI | `0x0594134DF3f171a354D9C85eBD65b7A6148F6D09` | No Chainlink feed |
| SHY / BND | `0xBE27…6FD8` / `0x2F62…7020` | No feed; duration risk |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | Not a vault asset |

## Gaps (documented, adapters are swappable)
- **No PAXG / XAUT / bullion-backed gold token** in the official list or Chainlink directory → gold exposure is the GLD Stock Token. Bridging (LayerZero is the listed bridge partner) would also need a Chainlink feed before it could be added via `PriceHistory.addAsset` + `SignalEngine.setDefensiveAssets` (Timelock).
- **No tokenized T-bill fund** (BUIDL, USTB, OUSG…) → SGOV Stock Token.
- **No L2 sequencer uptime feed** → OracleAdapter supports one; disabled until Chainlink publishes it.
- **Young feed history** — SPY/QQQ from 2026-06-22, SGOV from 2026-07-02, GLD from 2026-09-19. The first SPY/QQQ rounds are mis-scaled (~1e8×) and are filtered by the seed sanity band.

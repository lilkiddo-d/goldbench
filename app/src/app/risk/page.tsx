import type { Metadata } from "next";
import { AcceptDisclosure } from "@/components/AcceptDisclosure";

export const metadata: Metadata = { title: "Risk disclosure" };

export default function RiskPage() {
  return (
    <article className="prose-risk mx-auto max-w-3xl">
      <h1 className="text-3xl font-bold text-ink-100">Risk disclosure</h1>
      <p className="mt-2">
        Read this before depositing. Goldbench vaults are experimental, non-custodial smart contracts. You can lose some or
        all of your deposit. If you do not understand these risks, do not use the vaults.
      </p>

      <h2>1. Not investment advice</h2>
      <p>
        Nothing on this site is investment, legal, tax or financial advice, a recommendation, or an offer or solicitation
        to buy or sell any security or token. The vault strategies are mechanical rules published on-chain. They do not
        consider your circumstances. Past or simulated performance does not predict future results. Talk to a licensed
        professional before making investment decisions.
      </p>

      <h2>2. What the vaults hold</h2>
      <ul>
        <li>
          The SPY, QQQ, GLD and SGOV tokens are <strong>Robinhood Stock Tokens</strong>: tokenised{" "}
          <strong>debt securities</strong> issued by <strong>Robinhood Assets (Jersey) Limited</strong> (&quot;RHJ&quot;).
          They are not the underlying ETF shares. They give economic exposure only:{" "}
          <strong>
            token holders, including the vaults, have no legal or beneficial rights in the underlying securities (or
            bullion) and no rights against the issuer of those securities
          </strong>
          . There are no shareholder rights such as voting.
        </li>
        <li>
          The <strong>GLD token</strong> tracks the SPDR Gold Trust ETF. It is ETF exposure, <strong>not physical gold</strong>,
          and you cannot redeem it for metal.
        </li>
        <li>
          The <strong>SGOV token</strong> tracks an ETF that holds short-term US Treasury bills. It is ETF exposure, not a
          direct Treasury holding, and its value can move.
        </li>
        <li>
          Deposits and cash withdrawals use <strong>USDG</strong>, a stablecoin issued by Paxos. A stablecoin can lose its
          peg (<em>depeg</em>), be frozen, or be redeemable only on limited terms. The vaults block deposits and cash
          withdrawals when USDG trades away from $1, which can delay your exit.
        </li>
      </ul>

      <h2>3. Issuer and redemption risk</h2>
      <p>
        Because Stock Tokens are debt securities of RHJ, you carry <strong>issuer credit risk</strong>: their value depends
        on RHJ staying solvent and meeting its obligations, and on its custody and hedging arrangements, its handling of
        corporate actions and its continued support. <strong>Only Authorised Participants can mint or redeem with the
        issuer</strong> in the primary market. At issuance the only Authorised Participant is a single firm, and the
        primary market runs only from Monday 02:00 to Saturday 02:00 CET. End users, including the vaults, can only trade
        the tokens on-chain. Neither you nor the vaults can redeem tokens for the underlying assets. If secondary
        liquidity dries up, there may be no practical way to exit at a fair price. The issuer may pause, restrict or change
        tokens, transfers or oracles. Insolvency, regulatory action or operational failure could make tokens illiquid or
        worthless.
      </p>

      <h2>4. Smart-contract risk</h2>
      <p>
        The vaults, signal engine, price history, oracle adapter, DEX adapter, fee collector and related contracts are new
        software. They may contain bugs or design flaws that lead to loss of funds, even if they have been tested or
        reviewed. Admin functions sit behind a timelock, and a guardian can pause the vaults. Upgrades, misconfiguration or
        compromised keys are also risks. The underlying tokens, the Uniswap pools, the stablecoin and Robinhood Chain itself
        (a new network with a centralised sequencer) all carry their own technical risks.
      </p>

      <h2>5. Oracle risk</h2>
      <p>
        Valuations use Chainlink price feeds, and the signal uses closing prices recorded on-chain. Feeds can be stale,
        wrong, manipulated, paused by the issuer, or unavailable. Stock feeds stop updating outside US market hours. When
        prices are stale or deviate sharply from the last recorded close, <strong>deposits and cash withdrawals revert</strong>.
        Expect this on weekends and holidays. The NAV and share price shown in views fall back to the last recorded
        closes, so they can differ from live market prices.
      </p>

      <h2>6. Liquidity and execution risk</h2>
      <ul>
        <li>
          Rebalances trade through <strong>thin Uniswap v3 pools</strong>. Large trades can suffer slippage, fail, or only
          partly complete. Trades are split into chunks and protected with slippage limits, so a rebalance may finish
          late or not at all.
        </li>
        <li>
          <strong>Cash withdrawals are limited to the vault&apos;s idle USDG.</strong> Larger exits must use{" "}
          <strong>in-kind redemption</strong>, which is always available, even when paused. It sends you a pro-rata slice
          of every token the vault holds, and you may then find it hard to sell those tokens at a fair price.
        </li>
        <li>
          Deposits are subject to a per-vault cap, and transfers may be restricted by a compliance registry.
        </li>
      </ul>

      <h2>7. Strategy risk</h2>
      <ul>
        <li>
          The vaults follow a <strong>trend-following</strong> rule: a basket price vs its long moving average, with
          hysteresis and volatility scaling. Trend-following <strong>lags</strong>. It reacts after markets have already
          moved, can sell after a fall and buy after a rise, and can <strong>whipsaw</strong> (lose repeatedly) in sideways
          markets.
        </li>
        <li>
          Rebalances happen <strong>at most weekly and only during US market hours</strong>. The vaults cannot react to
          intraweek crashes, overnight gaps or weekend events.
        </li>
        <li>
          Gold and T-bills are not risk-free. Gold can fall while stocks fall. The stock cap (40% / 70% / 100%) limits
          exposure but does not limit losses.
        </li>
        <li>Signal parameters can change through governance and the timelock, within hard-coded bounds.</li>
      </ul>

      <h2>8. Fees</h2>
      <p>
        Each vault charges a <strong>management fee of 0.75% per year</strong>, accrued continuously by minting shares. The
        rate is capped in the contract code and cannot exceed 0.75%. There is <strong>no performance fee</strong>. You also
        pay gas, and the vault pays swap fees and slippage, which reduce returns.
      </p>

      <h2>9. Regulatory and geographic restrictions</h2>
      <p>
        Tokenized securities are restricted in many jurisdictions. According to the issuer, Stock Tokens{" "}
        <strong>may not be offered, sold or delivered in the United States or to U.S. persons</strong>, and are also
        restricted in other jurisdictions, including <strong>Canada, the United Kingdom and Switzerland</strong> (see the
        issuer&apos;s full list at{" "}
        <a className="text-gold-400 hover:underline" href="http://docs.robinhood.com/rhj" target="_blank" rel="noreferrer">
          docs.robinhood.com/rhj
        </a>
        ). <strong>The vaults hold these tokens, so the same restrictions apply to depositors.</strong> Do not use the
        vaults if you are a restricted person or located in a restricted jurisdiction. Access to this interface may be
        blocked by region. You alone
        must make sure your use is lawful where you live. Laws can change and may force the vaults, the issuer or this
        interface to restrict or wind down service.
      </p>

      <h2>10. No guarantee</h2>
      <p>
        There is no guarantee of any return, of capital preservation, of uninterrupted access to this interface, or that
        the strategy will perform as described. The contracts and this website are provided &quot;as is&quot;, without
        warranties of any kind. You are responsible for your own wallet security and transactions.
      </p>

      <AcceptDisclosure />
    </article>
  );
}

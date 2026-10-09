import Link from "next/link";
import { addressUrl } from "@/config/chain";
import { deployment } from "@/config/deployments";

export function Footer() {
  return (
    <footer className="border-t border-ink-700/70 py-8 text-xs text-ink-400">
      <div className="mx-auto flex max-w-6xl flex-col gap-3 px-4 sm:px-6 md:flex-row md:items-start md:justify-between">
        <p className="max-w-2xl leading-relaxed">
          Goldbench is non-custodial software. Nothing here is investment advice. Vault assets are third-party tokenized
          securities (Stock Tokens: debt securities of Robinhood Assets (Jersey) Limited) on Robinhood Chain; holders have no legal or beneficial rights in the underlying securities. Not available to U.S. persons or in other restricted jurisdictions.
          Read the{" "}
          <Link href="/risk" className="text-gold-400 underline-offset-2 hover:underline">
            risk disclosure
          </Link>{" "}
          before depositing.
        </p>
        <div className="flex flex-col gap-1 md:items-end">
          <span>
            Network: Robinhood Chain (4663) · deployment <code className="text-ink-300">{deployment.key}</code>
          </span>
          {!deployment.placeholder && (
            <a className="hover:text-ink-100" href={addressUrl(deployment.vaultFactory)} target="_blank" rel="noreferrer">
              Vault factory on Blockscout ↗
            </a>
          )}
        </div>
      </div>
    </footer>
  );
}

"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { TOKEN_ENABLED } from "@/config/env";
import { Logo } from "./Logo";
import { MarketBadge } from "./Badges";

const NAV = [
  { href: "/", label: "Vaults", match: (p: string) => p === "/" || p.startsWith("/vault") },
  { href: "/risk", label: "Risk", match: (p: string) => p.startsWith("/risk") },
  ...(TOKEN_ENABLED ? [{ href: "/stake", label: "Stake", match: (p: string) => p.startsWith("/stake") }] : []),
];

export function Header() {
  const path = usePathname() ?? "/";
  return (
    <header className="sticky top-0 z-30 border-b border-ink-700/70 bg-ink-950/80 backdrop-blur">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-x-6 gap-y-3 px-4 py-3 sm:px-6">
        <Link href="/" aria-label="Goldbench home">
          <Logo />
        </Link>
        <nav className="order-3 flex w-full gap-1 sm:order-none sm:w-auto">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={`rounded-lg px-3 py-1.5 text-sm font-medium transition ${
                n.match(path) ? "bg-ink-800 text-gold-300" : "text-ink-300 hover:text-ink-100"
              }`}
            >
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-3">
          <span className="hidden md:inline-flex">
            <MarketBadge />
          </span>
          <ConnectButton chainStatus="icon" showBalance={false} accountStatus={{ smallScreen: "avatar", largeScreen: "address" }} />
        </div>
      </div>
    </header>
  );
}

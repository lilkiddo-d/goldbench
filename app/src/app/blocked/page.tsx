import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Not available in your region" };
export const dynamic = "force-static";

export default function BlockedPage() {
  return (
    <div className="mx-auto max-w-xl py-16 text-center">
      <h1 className="text-2xl font-bold">
        <span className="gold-text">Goldbench</span> is not available in your region
      </h1>
      <p className="mt-4 text-ink-300">
        This interface can&apos;t be offered where you appear to be located, because of legal and regulatory
        restrictions on tokenized securities. We are sorry for the inconvenience.
      </p>
      <p className="mt-3 text-sm text-ink-400">
        If you already hold vault shares, you can still exit through the contracts directly (for example in-kind
        redemption via a block explorer).
      </p>
      <Link href="/risk" className="btn btn-ghost mt-8">
        Read the risk disclosure
      </Link>
    </div>
  );
}

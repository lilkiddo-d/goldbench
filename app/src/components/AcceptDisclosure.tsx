"use client";

import Link from "next/link";
import { useDisclosure } from "@/hooks/useDisclosure";

export function AcceptDisclosure() {
  const { accepted, setAccepted } = useDisclosure();
  return (
    <div className="card mt-10 p-5">
      <label className="flex cursor-pointer items-start gap-3 text-sm">
        <input
          type="checkbox"
          className="mt-1 h-4 w-4 accent-[#d4a73a]"
          checked={accepted}
          onChange={(e) => setAccepted(e.target.checked)}
        />
        <span className="text-ink-100">
          <strong>I understand.</strong> I have read this disclosure in full. I understand that Goldbench is experimental
          software, that this is not investment advice, that I may lose some or all of the money I deposit, and that I am
          responsible for complying with the laws that apply to me.
        </span>
      </label>
      <div className="mt-4 flex items-center gap-3 text-xs text-ink-400">
        {accepted ? (
          <>
            <span className="text-up">Accepted. Stored in this browser only.</span>
            <Link href="/" className="btn btn-gold px-3 py-1.5 text-xs">
              Go to vaults
            </Link>
          </>
        ) : (
          <span>Deposits stay disabled until you accept.</span>
        )}
      </div>
    </div>
  );
}

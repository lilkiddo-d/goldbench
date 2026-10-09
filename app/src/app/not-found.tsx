import Link from "next/link";

export default function NotFound() {
  return (
    <div className="mx-auto max-w-md py-20 text-center">
      <h1 className="text-2xl font-bold">
        <span className="gold-text">404</span> — nothing on this bench
      </h1>
      <p className="mt-3 text-ink-400">The page you&apos;re looking for doesn&apos;t exist.</p>
      <Link href="/" className="btn btn-gold mt-8">
        Back to vaults
      </Link>
    </div>
  );
}

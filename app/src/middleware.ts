import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. NEXT_PUBLIC_GEOBLOCK_COUNTRIES = comma-separated ISO-3166 alpha-2 codes (empty = off).
 * Country comes from Vercel's `x-vercel-ip-country` header. Blocked visitors are rewritten to /blocked;
 * /risk and /blocked themselves are never blocked.
 */
const BLOCKED = new Set(
  (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES || "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter((s) => /^[A-Z]{2}$/.test(s)),
);

export function middleware(req: NextRequest) {
  if (BLOCKED.size === 0) return NextResponse.next();
  const { pathname } = req.nextUrl;
  if (pathname === "/blocked" || pathname.startsWith("/blocked/") || pathname === "/risk" || pathname.startsWith("/risk/")) {
    return NextResponse.next();
  }
  const country = (req.headers.get("x-vercel-ip-country") || "").toUpperCase();
  if (country && BLOCKED.has(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    url.search = "";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  // Skip Next internals and static files.
  matcher: ["/((?!_next/static|_next/image|favicon.ico|icon.svg|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|txt|xml)$).*)"],
};

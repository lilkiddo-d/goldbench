export function LogoMark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <defs>
        <linearGradient id="gb-logo" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#f3d98b" />
          <stop offset="1" stopColor="#b08523" />
        </linearGradient>
      </defs>
      <rect width="64" height="64" rx="14" fill="#1d1b16" stroke="#3a362c" />
      <rect x="12" y="16" width="40" height="7" rx="2" fill="url(#gb-logo)" />
      <rect x="10" y="29" width="44" height="8" rx="2" fill="url(#gb-logo)" />
      <rect x="16" y="23" width="4" height="6" fill="#b08523" />
      <rect x="44" y="23" width="4" height="6" fill="#b08523" />
      <rect x="15" y="37" width="5" height="14" rx="1.5" fill="url(#gb-logo)" />
      <rect x="44" y="37" width="5" height="14" rx="1.5" fill="url(#gb-logo)" />
    </svg>
  );
}

export function Logo() {
  return (
    <span className="flex items-center gap-2.5">
      <LogoMark />
      <span className="text-lg font-bold tracking-tight">
        <span className="gold-text">Gold</span>
        <span className="text-ink-100">bench</span>
      </span>
    </span>
  );
}

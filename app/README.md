# Goldbench app

Next.js 15 (App Router) frontend for the Goldbench risk-rotation vaults on Robinhood Chain (chainId 4663).
Stack: wagmi v2, viem v2, RainbowKit v2, TanStack Query, Tailwind CSS v4, Recharts.

## Environment

Copy `.env.example` to `.env.local`. All variables are `NEXT_PUBLIC_*`, so they are inlined at **build** time.

| Variable | Default | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_RPC_URL` | `https://rpc.mainnet.chain.robinhood.com` | JSON-RPC endpoint (`http://127.0.0.1:8555` for the local fork) |
| `NEXT_PUBLIC_DEPLOYMENT` | `4663` | Loads `src/config/deployments.<value>.json` (`4663`, `4663-fork`) |
| `NEXT_PUBLIC_WC_PROJECT_ID` | empty | WalletConnect project id; empty = injected browser wallets only |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty | $GBEN address; empty hides `/stake`, rebates and governance |
| `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | empty (suggested `US,CA,GB,CH`) | Comma-separated ISO-3166 alpha-2 codes rewritten to `/blocked` (uses `x-vercel-ip-country`) |
| `NEXT_PUBLIC_LOG_SCAN_BLOCKS` | `2000000` | Blocks scanned per "load" of rebalance history (50k-block pages) |

Deployment files: `contracts/script/Deploy.s.sol` writes `src/config/deployments.<chainId>[-fork].json`.
The committed files are placeholders (`"placeholder": true`, zero addresses). While a placeholder is loaded, the UI
shows a "Not deployed yet" banner and makes no contract calls. To register another deployment file, add an import in
`src/config/deployments.ts`.

## Develop

```bash
pnpm install                 # from the repo root
pnpm --filter app dev        # http://localhost:3000
pnpm --filter app build      # production build (type-checks)
pnpm --filter app abis       # regenerate src/abi/generated.ts from contracts/out (after `forge build`)
```

`src/abi/generated.ts` is committed, so the app builds without Foundry.

Local fork: run anvil on port 8555, deploy with the fork suffix, then

```bash
NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8555 NEXT_PUBLIC_DEPLOYMENT=4663-fork pnpm --filter app dev
```

## Deploy on Vercel

- Root directory: `app`
- Install command: `pnpm install`
- Build command: `pnpm build` (preset in `vercel.json`)
- Set the environment variables above in the Vercel project. Geoblocking only works on Vercel, because it relies on the
  `x-vercel-ip-country` header.

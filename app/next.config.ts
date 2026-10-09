import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  eslint: { ignoreDuringBuilds: true },
  webpack: (config) => {
    // Optional peer deps pulled in by WalletConnect / MetaMask SDK that are not needed in the browser.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = {
      ...(config.resolve.fallback ?? {}),
      "@react-native-async-storage/async-storage": false,
    };
    // @base-org/account's node entry imports the server-only Coinbase CDP SDK (with optional x402 peers) for
    // payment helpers this app never calls. Stub it out so the SSR bundle resolves.
    config.resolve.alias = {
      ...(config.resolve.alias ?? {}),
      "@coinbase/cdp-sdk": false,
    };
    return config;
  },
};

export default nextConfig;

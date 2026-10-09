"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { darkTheme, RainbowKitProvider } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider } from "wagmi";
import { makeWagmiConfig } from "@/config/wagmi";
import { robinhoodChain } from "@/config/chain";

export function Providers({ children }: { children: ReactNode }) {
  const [config] = useState(() => makeWagmiConfig());
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: { queries: { staleTime: 15_000, refetchOnWindowFocus: false } },
      }),
  );
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          initialChain={robinhoodChain}
          theme={darkTheme({
            accentColor: "#d4a73a",
            accentColorForeground: "#1a1408",
            borderRadius: "medium",
            overlayBlur: "small",
          })}
          appInfo={{ appName: "Goldbench", learnMoreUrl: "/risk" }}
        >
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

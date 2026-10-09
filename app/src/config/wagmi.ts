import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { robinhoodChain } from "./chain";
import { RPC_URL, WC_PROJECT_ID } from "./env";

export function makeWagmiConfig() {
  const appName = "Goldbench";
  const connectors = WC_PROJECT_ID
    ? connectorsForWallets(
        [
          { groupName: "Popular", wallets: [metaMaskWallet, rabbyWallet, coinbaseWallet, rainbowWallet] },
          { groupName: "Other", wallets: [walletConnectWallet, injectedWallet] },
        ],
        { appName, projectId: WC_PROJECT_ID },
      )
    : // No WalletConnect project id: injected (browser-extension) wallets only.
      connectorsForWallets([{ groupName: "Browser wallet", wallets: [injectedWallet, rabbyWallet] }], {
        appName,
        projectId: "unused",
      });

  return createConfig({
    chains: [robinhoodChain],
    connectors,
    transports: {
      [robinhoodChain.id]: http(RPC_URL, { retryCount: 3, retryDelay: 500 }),
    },
    batch: { multicall: { wait: 16 } },
    ssr: true,
  });
}

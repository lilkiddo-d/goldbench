import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "./providers";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";
import { DeploymentBanner } from "@/components/DeploymentBanner";

export const metadata: Metadata = {
  title: { default: "Goldbench — risk-rotation vaults", template: "%s · Goldbench" },
  description:
    "Goldbench: ERC-4626 vaults that rotate between a tokenized-stock basket and tokenized gold + T-bills, following a transparent on-chain trend signal.",
  icons: { icon: "/icon.svg" },
};

export const viewport: Viewport = { themeColor: "#0b0a08" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="font-sans antialiased">
        <Providers>
          <div className="flex min-h-screen flex-col">
            <Header />
            <DeploymentBanner />
            <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-6">{children}</main>
            <Footer />
          </div>
        </Providers>
      </body>
    </html>
  );
}

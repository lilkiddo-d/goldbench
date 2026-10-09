import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { TOKEN_ENABLED } from "@/config/env";
import { StakeView } from "./StakeView";

export const metadata: Metadata = { title: "Stake $GBEN" };

export default function StakePage() {
  if (!TOKEN_ENABLED) notFound();
  return <StakeView />;
}

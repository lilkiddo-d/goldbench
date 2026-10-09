import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { VAULTS, vaultBySlug } from "@/config/vaults";
import { VaultDetail } from "./VaultDetail";

export function generateStaticParams() {
  return VAULTS.map((v) => ({ slug: v.slug }));
}

export const dynamicParams = false;

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params;
  const v = vaultBySlug(slug);
  return { title: v ? `${v.name} vault` : "Vault" };
}

export default async function VaultPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const v = vaultBySlug(slug);
  if (!v) notFound();
  return <VaultDetail slug={v.slug} />;
}

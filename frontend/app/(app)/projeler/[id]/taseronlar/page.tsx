import { redirect } from "next/navigation";

import { subcontractsTabHref } from "@/lib/subcontracts";

// /projeler/{id}/taseronlar (mobilin liste yolu) web'de proje detayının
// Taşeronlar sekmesidir.
export default async function TaseronlarPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  redirect(subcontractsTabHref(id));
}

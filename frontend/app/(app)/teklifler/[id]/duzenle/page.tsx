import { redirect } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Offer } from "@/lib/types";

import { OfferForm } from "../../OfferForm";

export default async function TeklifDuzenlePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const offer = await apiServer<Offer>(`/api/v1/offers/${id}`, cookieHeader);

  // Yalnızca taslak teklifler düzenlenebilir -- backend zaten bunu
  // zorunlu kılıyor (409), burada yalnızca gereksiz bir form gösterimini
  // önlemek için erken yönlendirme.
  if (offer.status !== "taslak") {
    redirect(`/teklifler/${id}`);
  }

  return (
    <>
      <PageHeader title={`${offer.offer_no} — Düzenle`} />
      <OfferForm offer={offer} />
    </>
  );
}

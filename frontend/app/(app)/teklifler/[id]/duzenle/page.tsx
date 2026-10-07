import { redirect } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { Offer } from "@/lib/types";

import { OfferForm } from "../../OfferForm";

export default async function TeklifDuzenlePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.offers);
  const { id } = await params;
  if (!hasPermission(user.permissions, "offers.update")) redirect(`/teklifler/${id}`);
  const cookieHeader = (await cookies()).toString();
  const offer = await apiServer<Offer>(`/api/v1/offers/${id}`, cookieHeader);

  // Yalnızca taslak teklifler düzenlenebilir -- backend zaten bunu
  // zorunlu kılıyor (409), burada yalnızca gereksiz bir form gösterimini
  // önlemek için erken yönlendirme.
  if (offer.status !== "taslak") {
    redirect(`/teklifler/${id}`);
  }

  const canManageInternalPricing = hasPermission(user.permissions, "offers.internal_pricing.manage");

  return (
    <>
      <PageHeader title={`${offer.offer_no} — Düzenle`} />
      <OfferForm
        offer={offer}
        canManageInternalPricing={canManageInternalPricing}
        canReadCustomers={hasPermission(user.permissions, "customers.read")}
        canManageCustomers={hasPermission(user.permissions, "customers.manage")}
        canReadProducts={hasPermission(user.permissions, "products.read")}
      />
    </>
  );
}

import { redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { requirePagePermission } from "@/lib/auth";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";

import { OfferForm } from "../OfferForm";

export default async function YeniTeklifPage() {
  const user = await requirePagePermission(PAGE_PERMISSIONS.offers);
  if (!hasPermission(user.permissions, "offers.create")) redirect("/teklifler");
  const canManageInternalPricing = hasPermission(user.permissions, "offers.internal_pricing.manage");
  return (
    <>
      <PageHeader title="Yeni Teklif" />
      <OfferForm
        canManageInternalPricing={canManageInternalPricing}
        canReadCustomers={hasPermission(user.permissions, "customers.read")}
        canManageCustomers={hasPermission(user.permissions, "customers.manage")}
        canReadProducts={hasPermission(user.permissions, "products.read")}
      />
    </>
  );
}

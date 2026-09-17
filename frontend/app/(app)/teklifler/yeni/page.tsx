import { PageHeader } from "@/components/layout/PageHeader";
import { getCurrentUser } from "@/lib/auth";

import { OfferForm } from "../OfferForm";

export default async function YeniTeklifPage() {
  const user = await getCurrentUser();
  const canManageInternalPricing = user?.permissions?.includes("offers.internal_pricing.manage") ?? false;
  return (
    <>
      <PageHeader title="Yeni Teklif" />
      <OfferForm canManageInternalPricing={canManageInternalPricing} />
    </>
  );
}

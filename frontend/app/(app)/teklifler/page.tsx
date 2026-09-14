import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/Button";
import { Tabs } from "@/components/ui/Tabs";
import { apiServer } from "@/lib/api";
import type { Offer } from "@/lib/types";

import { OffersBoard } from "./OffersBoard";

async function fetchOffers(filter: string) {
  const cookieHeader = (await cookies()).toString();
  return apiServer<{ offers: Offer[]; total: number }>(
    `/api/v1/offers?filter=${filter}`,
    cookieHeader
  );
}

export default async function TekliflerPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string }>;
}) {
  const { filter = "aktif" } = await searchParams;
  const { offers } = await fetchOffers(filter);

  return (
    <>
      <PageHeader
        title="Teklifler"
        action={
          <Link href="/teklifler/yeni">
            <Button>+ Yeni Teklif</Button>
          </Link>
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <p className="-mt-1 text-sm text-text-muted">
          Tekliflerinizi oluşturun, takip edin ve müşterilerinize gönderin.
        </p>
        <Tabs
          items={[
            { key: "aktif", label: "Aktif", active: filter === "aktif", href: "/teklifler?filter=aktif" },
            { key: "pasif", label: "Pasif", active: filter === "pasif", href: "/teklifler?filter=pasif" },
          ]}
        />
        <OffersBoard offers={offers} />
      </div>
    </>
  );
}

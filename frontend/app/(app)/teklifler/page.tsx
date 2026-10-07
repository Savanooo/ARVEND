import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/Button";
import { Tabs } from "@/components/ui/Tabs";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { Offer, OfferStatus } from "@/lib/types";

import { OffersBoard, type OfferListParams } from "./OffersBoard";

const PAGE_SIZE = 50;

type OfferListResponse = {
  offers: Offer[];
  total: number;
  status_counts: Record<OfferStatus, number>;
};

// Durum/arama/tarih filtreleri ve sayfalama SUNUCUDA uygulanır (bkz.
// backend OfferHandler.List). Eskiden yalnızca ilk 50 teklif çekilip
// tarayıcıda süzülüyordu: 51. ve sonraki teklifler hiçbir filtrede
// görünmüyor, sayaçlar ve "N teklif" yalnızca yüklenen satırları sayıyordu.
async function fetchOffers(params: OfferListParams, page: number) {
  const query = new URLSearchParams({ filter: params.filter, page: String(page), limit: String(PAGE_SIZE) });
  if (params.status) query.set("status", params.status);
  if (params.q) query.set("q", params.q);
  if (params.from) query.set("date_from", params.from);
  if (params.to) query.set("date_to", params.to);
  const cookieHeader = (await cookies()).toString();
  return apiServer<OfferListResponse>(`/api/v1/offers?${query.toString()}`, cookieHeader);
}

export default async function TekliflerPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string; status?: string; q?: string; from?: string; to?: string; page?: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.offers);
  const sp = await searchParams;
  const params: OfferListParams = {
    filter: sp.filter === "pasif" ? "pasif" : "aktif",
    status: sp.status ?? "",
    q: sp.q ?? "",
    from: sp.from ?? "",
    to: sp.to ?? "",
  };
  const page = Math.max(1, Number(sp.page ?? "1") || 1);
  const { offers, total, status_counts } = await fetchOffers(params, page);
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <>
      <PageHeader
        title="Teklifler"
        action={
          hasPermission(user.permissions, "offers.create") ? (
            <Link href="/teklifler/yeni">
              <Button>+ Yeni Teklif</Button>
            </Link>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <p className="-mt-1 text-sm text-text-muted">
          Tekliflerinizi oluşturun, takip edin ve müşterilerinize gönderin.
        </p>
        <Tabs
          items={[
            { key: "aktif", label: "Aktif", active: params.filter === "aktif", href: "/teklifler?filter=aktif" },
            { key: "pasif", label: "Pasif", active: params.filter === "pasif", href: "/teklifler?filter=pasif" },
          ]}
        />
        <OffersBoard
          key={`${params.filter}|${params.status}|${params.q}|${params.from}|${params.to}`}
          offers={offers}
          total={total}
          statusCounts={status_counts}
          params={params}
          page={page}
          totalPages={totalPages}
        />
      </div>
    </>
  );
}

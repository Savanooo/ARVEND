import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { Offer, OfferStatus } from "@/lib/types";

const STATUS_TONE: Record<OfferStatus, "muted" | "gold" | "success" | "danger"> = {
  "taslak": "muted",
  "gönderildi": "gold",
  "kabul edildi": "success",
  "reddedildi": "danger",
};

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
  const { offers, total } = await fetchOffers(filter);

  return (
    <>
      <Topbar
        title="Teklifler"
        action={
          <Link href="/teklifler/yeni">
            <Button>+ Yeni Teklif</Button>
          </Link>
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <div className="flex gap-2 text-sm">
          <Link
            href="/teklifler?filter=aktif"
            className={filter === "aktif" ? "font-semibold text-gold" : "text-text-muted"}
          >
            Aktif
          </Link>
          <span className="text-text-muted">·</span>
          <Link
            href="/teklifler?filter=pasif"
            className={filter === "pasif" ? "font-semibold text-gold" : "text-text-muted"}
          >
            Pasif
          </Link>
        </div>
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Teklif No</Th>
                <Th>Müşteri</Th>
                <Th>Tarih</Th>
                <Th>Durum</Th>
                <Th className="text-right">Tutar</Th>
              </tr>
            </thead>
            <tbody>
              {offers.map((o) => (
                <Tr key={o.id}>
                  <Td>
                    <Link
                      href={`/teklifler/${o.id}`}
                      className="font-medium hover:text-gold hover:underline"
                    >
                      {o.offer_no}
                    </Link>
                  </Td>
                  <Td className="text-text-muted">{o.customer_name}</Td>
                  <Td className="text-text-muted">
                    {new Date(o.offer_date).toLocaleDateString("tr-TR")}
                  </Td>
                  <Td>
                    <Badge tone={STATUS_TONE[o.status]}>{o.status}</Badge>
                  </Td>
                  <Td className="text-right font-medium">{formatTL(o.grand_total)}</Td>
                </Tr>
              ))}
              {offers.length === 0 && (
                <tr>
                  <Td colSpan={5} className="text-center text-text-muted">
                    Teklif bulunamadı.
                  </Td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
        <p className="text-xs text-text-muted">{total} teklif</p>
      </div>
    </>
  );
}

import { cookies } from "next/headers";

import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { formatTL } from "@/lib/format";
import { OFFER_STATUS } from "@/lib/status";
import type { OfferRevision } from "@/lib/types";

export default async function TeklifRevizyonDetayPage({
  params,
}: {
  params: Promise<{ id: string; revisionId: string }>;
}) {
  const { id, revisionId } = await params;
  const cookieHeader = (await cookies()).toString();
  const revision = await apiServer<OfferRevision>(
    `/api/v1/offers/${id}/revisions/${revisionId}`,
    cookieHeader
  );
  const hasInternalPricing = revision.items?.some((it) => it.internal_pricing) ?? false;

  return (
    <>
      <PageHeader title={`Revizyon ${revision.revision_no}`} />
      <div className="flex flex-col gap-6 p-8 lg:flex-row">
        <div className="flex flex-1 flex-col gap-6">
          <Card>
            <CardHeader>Kalemler (salt okunur — bu revizyon geçmişte donmuştur)</CardHeader>
            <Table>
              <thead>
                <tr>
                  <Th>Ürün / Hizmet</Th>
                  <Th className="text-right">Miktar</Th>
                  <Th className="text-right">Birim Fiyat</Th>
                  <Th className="text-right">Tutar</Th>
                  {hasInternalPricing && (
                    <>
                      <Th className="text-right text-gold">İç Maliyet</Th>
                      <Th className="text-right text-gold">Beklenen Kâr</Th>
                    </>
                  )}
                </tr>
              </thead>
              <tbody>
                {revision.items?.map((it) => (
                  <Tr key={it.id}>
                    <Td className="font-medium">{it.product_name}</Td>
                    <Td className="text-right">{it.quantity}</Td>
                    <Td className="text-right">{formatTL(it.unit_price)}</Td>
                    <Td className="text-right font-medium">{formatTL(it.line_total)}</Td>
                    {hasInternalPricing && (
                      <>
                        <Td className="text-right text-text-muted">
                          {it.internal_pricing ? formatTL(it.internal_pricing.cost) : "—"}
                        </Td>
                        <Td className="text-right text-text-muted">
                          {it.internal_pricing ? formatTL(it.internal_pricing.expected_profit) : "—"}
                        </Td>
                      </>
                    )}
                  </Tr>
                ))}
              </tbody>
            </Table>
            <CardBody className="flex flex-col items-end gap-1 border-t border-border">
              <div className="flex w-48 justify-between text-sm text-text-muted">
                <span>Ara Toplam</span>
                <span>{formatTL(revision.subtotal)}</span>
              </div>
              <div className="flex w-48 justify-between text-sm text-text-muted">
                <span>KDV (%{revision.vat_rate})</span>
                <span>{formatTL(revision.vat_amount)}</span>
              </div>
              <div className="flex w-48 justify-between text-base font-bold">
                <span>Genel Toplam</span>
                <span>{formatTL(revision.grand_total)}</span>
              </div>
            </CardBody>
          </Card>

          {revision.notes && (
            <Card>
              <CardHeader>Notlar</CardHeader>
              <CardBody className="text-sm text-text-muted">{revision.notes}</CardBody>
            </Card>
          )}
        </div>

        <div className="flex w-full flex-col gap-6 lg:w-80">
          <Card className="h-fit">
            <CardHeader>Müşteri</CardHeader>
            <CardBody className="flex flex-col gap-1 text-sm">
              <div className="font-medium">{revision.customer_name}</div>
              {revision.customer_phone && (
                <div className="text-text-muted">{revision.customer_phone}</div>
              )}
              {revision.customer_email && (
                <div className="text-text-muted">{revision.customer_email}</div>
              )}
              {revision.customer_address && (
                <div className="text-text-muted">{revision.customer_address}</div>
              )}
              <div className="mt-3 border-t border-border pt-3 text-xs uppercase tracking-widest text-text-muted">
                Oluşturulma
              </div>
              <div>{new Date(revision.created_at).toLocaleString("tr-TR")}</div>
              <div className="mt-3 border-t border-border pt-3 text-xs uppercase tracking-widest text-text-muted">
                Durum
              </div>
              <div>
                <StatusBadge status={revision.status} registry={OFFER_STATUS} />
              </div>
            </CardBody>
          </Card>
        </div>
      </div>
    </>
  );
}

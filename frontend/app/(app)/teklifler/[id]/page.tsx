import { cookies } from "next/headers";

import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { Offer } from "@/lib/types";

import { OfferActions } from "./OfferActions";

export default async function TeklifDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const offer = await apiServer<Offer>(`/api/v1/offers/${id}`, cookieHeader);

  return (
    <>
      <Topbar title={offer.offer_no} action={<OfferActions offer={offer} />} />
      <div className="flex flex-col gap-6 p-8 lg:flex-row">
        <div className="flex flex-1 flex-col gap-6">
          <Card>
            <CardHeader>Kalemler</CardHeader>
            <Table>
              <thead>
                <tr>
                  <Th>Ürün / Hizmet</Th>
                  <Th className="text-right">Miktar</Th>
                  <Th className="text-right">Birim Fiyat</Th>
                  <Th className="text-right">Tutar</Th>
                </tr>
              </thead>
              <tbody>
                {offer.items?.map((it) => (
                  <Tr key={it.id}>
                    <Td className="font-medium">{it.product_name}</Td>
                    <Td className="text-right">{it.quantity}</Td>
                    <Td className="text-right">{formatTL(it.unit_price)}</Td>
                    <Td className="text-right font-medium">{formatTL(it.line_total)}</Td>
                  </Tr>
                ))}
              </tbody>
            </Table>
            <CardBody className="flex flex-col items-end gap-1 border-t border-border">
              <div className="flex w-48 justify-between text-sm text-text-muted">
                <span>Ara Toplam</span>
                <span>{formatTL(offer.subtotal)}</span>
              </div>
              <div className="flex w-48 justify-between text-sm text-text-muted">
                <span>KDV (%{offer.vat_rate})</span>
                <span>{formatTL(offer.vat_amount)}</span>
              </div>
              <div className="flex w-48 justify-between text-base font-bold">
                <span>Genel Toplam</span>
                <span>{formatTL(offer.grand_total)}</span>
              </div>
            </CardBody>
          </Card>

          {offer.notes && (
            <Card>
              <CardHeader>Notlar</CardHeader>
              <CardBody className="text-sm text-text-muted">{offer.notes}</CardBody>
            </Card>
          )}
        </div>

        <Card className="h-fit w-full lg:w-80">
          <CardHeader>Müşteri</CardHeader>
          <CardBody className="flex flex-col gap-1 text-sm">
            <div className="font-medium">{offer.customer_name}</div>
            {offer.customer_phone && (
              <div className="text-text-muted">{offer.customer_phone}</div>
            )}
            {offer.customer_email && (
              <div className="text-text-muted">{offer.customer_email}</div>
            )}
            {offer.customer_address && (
              <div className="text-text-muted">{offer.customer_address}</div>
            )}
            <div className="mt-3 border-t border-border pt-3 text-xs uppercase tracking-widest text-text-muted">
              Teklif Tarihi
            </div>
            <div>{new Date(offer.offer_date).toLocaleDateString("tr-TR")}</div>
          </CardBody>
        </Card>
      </div>
    </>
  );
}

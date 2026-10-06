import { Badge } from "@/components/ui/Badge";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PublicPageHeader } from "@/components/layout/PublicPageHeader";
import { apiServer, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { Offer, OfferStatus } from "@/lib/types";

import { RespondButtons } from "./RespondButtons";

const STATUS_TONE: Record<OfferStatus, "success" | "gold" | "danger" | "muted"> = {
  taslak: "muted",
  gönderildi: "gold",
  "kabul edildi": "success",
  reddedildi: "danger",
};

// can_respond, backend'in "bu bağlantı üzerinden ŞU AN karar verilebilir
// mi?" cevabıdır (bağlı revizyon hâlâ güncel VE gönderildi durumunda mı).
// Kabul/Reddet butonları buna göre gösterilir -- teklifin durumuna bakmak
// yetmez, çünkü gösterilen durum linkin bağlı olduğu (donmuş) revizyonun
// durumudur.
//
// validity_expired: geçerlilik tarihi (o gün dahil) geçmiş -- "bugün"ü
// sunucu belirler (İstanbul takvim günü), tarayıcı saatine bakılmaz.
//
// organization_name: teklifi veren firmanın adı (sayfa başlığı).
type PublicOffer = Offer & { can_respond: boolean; validity_expired: boolean; organization_name: string };

type FetchResult = { offer: PublicOffer; error: null } | { offer: null; error: ApiError };

async function fetchOffer(token: string): Promise<FetchResult> {
  try {
    return { offer: await apiServer<PublicOffer>(`/api/v1/public/offers/${token}/`, ""), error: null };
  } catch (err) {
    if (err instanceof ApiError) return { offer: null, error: err };
    throw err;
  }
}

// 410 Gone: link bir zamanlar geçerliydi (iptal edildi / süresi doldu);
// 404: böyle bir link hiç yok. Müşteriye ikisi için farklı, ama teklif
// içeriğinden hiçbir şey sızdırmayan mesajlar gösterilir.
function unavailableMessage(error: ApiError) {
  if (error.status === 410) {
    return "Bu paylaşım bağlantısı artık geçerli değil: iptal edilmiş veya süresi dolmuş olabilir. Lütfen teklifi gönderen firmayla iletişime geçin.";
  }
  return "Bu bağlantıya ait bir teklif bulunamadı. Bağlantı geçersiz olabilir.";
}

export default async function PaylasPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const { offer, error } = await fetchOffer(token);

  return (
    <div className="mx-auto flex min-h-screen max-w-2xl flex-col gap-6 p-6 sm:p-10">
      <PublicPageHeader organizationName={offer?.organization_name} subtitle="Teklif Görüntüleme" />

      {!offer ? (
        <Card>
          <CardBody className="text-center text-text-muted">{unavailableMessage(error)}</CardBody>
        </Card>
      ) : (
        <>
          <Card>
            <CardHeader className="flex items-center justify-between">
              <span>{offer.offer_no}</span>
              <Badge tone={STATUS_TONE[offer.status]}>{offer.status}</Badge>
            </CardHeader>
            <CardBody className="flex flex-col gap-1 text-sm">
              <div className="font-medium">{offer.customer_name}</div>
              {offer.customer_phone && (
                <div className="text-text-muted">{offer.customer_phone}</div>
              )}
              {offer.customer_address && (
                <div className="text-text-muted">{offer.customer_address}</div>
              )}
              <div className="mt-1 text-xs text-text-muted">
                Teklif Tarihi: {new Date(offer.offer_date).toLocaleDateString("tr-TR")}
                {offer.valid_until && (
                  <> · Geçerlilik: {new Date(offer.valid_until).toLocaleDateString("tr-TR")}</>
                )}
              </div>
            </CardBody>
          </Card>

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

          {offer.can_respond && <RespondButtons token={token} />}
          {offer.status === "kabul edildi" && (
            <p className="text-center text-sm text-success">Bu teklifi kabul ettiniz.</p>
          )}
          {offer.status === "reddedildi" && (
            <p className="text-center text-sm text-danger">Bu teklifi reddettiniz.</p>
          )}
          {offer.status === "gönderildi" && offer.validity_expired && offer.valid_until && (
            <p className="text-center text-sm text-text-muted">
              Bu teklifin geçerlilik süresi{" "}
              {new Date(offer.valid_until).toLocaleDateString("tr-TR")} tarihinde doldu; bu teklif
              artık onaylanamaz veya reddedilemez. Güncel bir teklif için lütfen teklifi gönderen
              firmayla iletişime geçin.
            </p>
          )}
          {!offer.can_respond && offer.status === "gönderildi" && !offer.validity_expired && (
            <p className="text-center text-sm text-text-muted">
              Bu teklif için daha güncel bir revizyon hazırlanmıştır; bu bağlantı üzerinden karar
              verilemez. Lütfen size en son gönderilen bağlantıyı kullanın.
            </p>
          )}
        </>
      )}
    </div>
  );
}

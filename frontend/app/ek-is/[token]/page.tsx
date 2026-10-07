import { Badge } from "@/components/ui/Badge";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PublicPageHeader } from "@/components/layout/PublicPageHeader";
import { apiServer, ApiError } from "@/lib/api";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import { CHANGE_ORDER_TYPE_LABELS, type ChangeOrderStatus, type PublicChangeOrder } from "@/lib/types";

import { RespondButtons } from "./RespondButtons";

const STATUS_TONE: Record<ChangeOrderStatus, "success" | "gold" | "danger" | "muted"> = {
  draft: "muted",
  sent: "gold",
  approved: "success",
  rejected: "danger",
  cancelled: "danger",
  superseded: "muted",
};

const STATUS_LABEL: Record<ChangeOrderStatus, string> = {
  draft: "Taslak",
  sent: "Gönderildi",
  approved: "Onaylandı",
  rejected: "Reddedildi",
  cancelled: "İptal",
  superseded: "Yerine Yeni Revizyon Oluşturuldu",
};

// organization_name: ek işi gönderen firmanın adı (sayfa başlığı).
type PublicChangeOrderWithOrg = PublicChangeOrder & { organization_name?: string };

type FetchResult =
  | { changeOrder: PublicChangeOrderWithOrg; error: null }
  | { changeOrder: null; error: ApiError };

async function fetchChangeOrder(token: string): Promise<FetchResult> {
  try {
    return {
      changeOrder: await apiServer<PublicChangeOrderWithOrg>(`/api/v1/public/change-orders/${token}/`, ""),
      error: null,
    };
  } catch (err) {
    if (err instanceof ApiError) return { changeOrder: null, error: err };
    throw err;
  }
}

// 410 Gone: link bir zamanlar geçerliydi (iptal edildi/revize edildi/
// süresi doldu); 404: böyle bir link hiç yok. Müşteriye ikisi için
// farklı, ama içerikten hiçbir şey sızdırmayan mesajlar gösterilir.
function unavailableMessage(error: ApiError) {
  if (error.status === 410) {
    return "Bu paylaşım bağlantısı artık geçerli değil: iptal edilmiş veya süresi dolmuş olabilir. Lütfen firmayla iletişime geçin.";
  }
  return "Bu bağlantıya ait bir ek iş bulunamadı. Bağlantı geçersiz olabilir.";
}

export default async function EkIsPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const { changeOrder: co, error } = await fetchChangeOrder(token);

  return (
    <div className="mx-auto flex min-h-screen max-w-2xl flex-col gap-6 p-6 sm:p-10">
      <PublicPageHeader
        organizationName={co?.organization_name}
        subtitle="Ek İş / Değişiklik Emri Görüntüleme"
      />

      {!co ? (
        <Card>
          <CardBody className="text-center text-text-muted">{unavailableMessage(error)}</CardBody>
        </Card>
      ) : (
        <>
          <Card>
            <CardHeader className="flex items-center justify-between">
              <span>
                {co.project_no} / {co.change_order_no}
              </span>
              <Badge tone={STATUS_TONE[co.status]}>{STATUS_LABEL[co.status]}</Badge>
            </CardHeader>
            <CardBody className="flex flex-col gap-1 text-sm">
              <div className="font-medium">{co.title}</div>
              <div className="text-text-muted">
                {co.project_name} · {co.customer_name}
              </div>
              <div className="mt-1 text-xs uppercase tracking-widest text-text-muted">
                {CHANGE_ORDER_TYPE_LABELS[co.change_type]}
              </div>
              {co.description && <div className="mt-1 text-text-muted">{co.description}</div>}
            </CardBody>
          </Card>

          <Card>
            <CardHeader>Kalemler</CardHeader>
            <Table>
              <thead>
                <tr>
                  <Th>Açıklama</Th>
                  <Th className="text-right">Miktar</Th>
                  <Th className="text-right">Birim Fiyat</Th>
                  <Th className="text-right">Tutar</Th>
                </tr>
              </thead>
              <tbody>
                {co.items.map((it) => (
                  <Tr key={it.id}>
                    <Td className="font-medium">{it.description}</Td>
                    <Td className="text-right">
                      {it.quantity} {it.unit}
                    </Td>
                    <Td className="text-right">{formatMoney(it.unit_price, co.currency)}</Td>
                    <Td className="text-right font-medium">{formatMoney(it.line_total, co.currency)}</Td>
                  </Tr>
                ))}
              </tbody>
            </Table>
            <CardBody className="flex flex-col items-end gap-1 border-t border-border">
              <div className="flex w-48 justify-between text-sm text-text-muted">
                <span>Ara Toplam</span>
                <span>{formatMoney(co.subtotal, co.currency)}</span>
              </div>
              <div className="flex w-48 justify-between text-sm text-text-muted">
                <span>KDV (%{co.vat_rate})</span>
                <span>{formatMoney(co.vat_amount, co.currency)}</span>
              </div>
              <div className="flex w-48 justify-between text-base font-bold">
                <span>Genel Toplam</span>
                <span>{formatMoney(co.grand_total, co.currency)}</span>
              </div>
            </CardBody>
          </Card>

          {/* Ticari etki açıkça gösterilir -- yalnızca ana sözleşme/güncel/
              onaylanırsa oluşacak bedel; hiçbir maliyet/kâr alanı YOKTUR. */}
          <Card>
            <CardHeader>Proje Bedeline Etkisi</CardHeader>
            <CardBody className="flex flex-col gap-1 text-sm">
              <div className="flex justify-between">
                <span className="text-text-muted">Ana Sözleşme</span>
                <span>{formatMoney(co.base_contract_amount, co.currency)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Mevcut Güncel Proje Bedeli</span>
                <span>{formatMoney(co.current_contract_value, co.currency)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Bu {CHANGE_ORDER_TYPE_LABELS[co.change_type]}</span>
                <span className={co.change_type === "addition" ? "text-success" : "text-danger"}>
                  {formatSignedMoney(co.change_type === "deduction" ? -co.grand_total : co.grand_total, co.currency)}
                </span>
              </div>
              <div className="mt-1 flex justify-between border-t border-border pt-1 text-base font-bold">
                <span>Onaylanırsa Yeni Proje Bedeli</span>
                <span>{formatMoney(co.projected_contract_value, co.currency)}</span>
              </div>
            </CardBody>
          </Card>

          {co.customer_notes && (
            <Card>
              <CardHeader>Notlar</CardHeader>
              <CardBody className="text-sm text-text-muted">{co.customer_notes}</CardBody>
            </Card>
          )}

          {co.can_respond && <RespondButtons token={token} />}
          {co.status === "approved" && <p className="text-center text-sm text-success">Bu ek işi onayladınız.</p>}
          {co.status === "rejected" && <p className="text-center text-sm text-danger">Bu ek işi reddettiniz.</p>}
          {!co.can_respond && co.status === "sent" && (
            <p className="text-center text-sm text-text-muted">
              Bu ek iş için daha güncel bir revizyon hazırlanmıştır; bu bağlantı üzerinden karar
              verilemez. Lütfen size en son gönderilen bağlantıyı kullanın.
            </p>
          )}
        </>
      )}
    </div>
  );
}

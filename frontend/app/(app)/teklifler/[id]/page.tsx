import Link from "next/link";
import { cookies } from "next/headers";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer, ApiError } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatTL } from "@/lib/format";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
import { orNotFound } from "@/lib/server-data";
import { OFFER_STATUS } from "@/lib/status";
import type {
  Offer,
  OfferEmailLog,
  OfferEvent,
  OfferRevision,
  OfferShareLink,
  Project,
} from "@/lib/types";

import { ActivityTimeline } from "./ActivityTimeline";
import { DownloadPdfButton } from "./DownloadPdfButton";
import { OfferActions } from "./OfferActions";
import { ShareOfferCard } from "./ShareOfferCard";

export default async function TeklifDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.offers);
  const canUpdate = hasPermission(user.permissions, "offers.update");
  const canCreateProject = hasPermission(user.permissions, "projects.create");
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  // Silinmiş teklife giden bayat bağlantı (ör. bildirim) 404 -> "Kayıt bulunamadı".
  const [offer, { revisions }, { share_links }, { events }, { email_logs }] = await orNotFound(
    Promise.all([
      apiServer<Offer>(`/api/v1/offers/${id}`, cookieHeader),
      apiServer<{ revisions: OfferRevision[] }>(`/api/v1/offers/${id}/revisions`, cookieHeader),
      apiServer<{ share_links: OfferShareLink[] }>(`/api/v1/offers/${id}/share-links`, cookieHeader),
      apiServer<{ events: OfferEvent[] }>(`/api/v1/offers/${id}/events`, cookieHeader),
      apiServer<{ email_logs: OfferEmailLog[] }>(`/api/v1/offers/${id}/email-logs`, cookieHeader),
    ])
  );
  const revisionNoById: Record<string, number> = Object.fromEntries(
    revisions.map((r) => [r.id, r.revision_no])
  );

  // Teklif zaten projeye dönüştürülmüş mü? 404 = dönüştürülmemiş.
  // 403 = dönüştürülmüş ama kullanıcının o projeye erişimi (projects.read +
  // proje üyeliği) yok -- backend proje verisini artık yalnızca erişimi
  // olana döner; bu durumda ne "Projeyi Görüntüle" ne "Projeye Dönüştür"
  // gösterilir.
  const projectLookup = await apiServer<Project>(`/api/v1/offers/${id}/project`, cookieHeader).then(
    (p) => ({ project: p as Project | null, accessDenied: false }),
    (err) => {
      if (err instanceof ApiError) return { project: null, accessDenied: err.status === 403 };
      throw err;
    }
  );
  const { project, accessDenied: projectAccessDenied } = projectLookup;

  // internal_pricing alanı backend'de YALNIZCA offers.internal_pricing.read
  // izni olan personel için doldurulur (bkz. offer_handler.go
  // attachInternalPricing) -- burada AYRICA bir izin kontrolü YAPILMAZ,
  // alanın varlığı/yokluğu TEK gerçek kaynaktır.
  const hasInternalPricing = offer.items?.some((it) => it.internal_pricing) ?? false;

  return (
    <>
      <PageHeader
        title={
          <span className="flex items-center gap-3">
            {offer.offer_no}
            <StatusBadge status={offer.status} registry={OFFER_STATUS} />
          </span>
        }
        action={
          <div className="flex items-center gap-3">
            <DownloadPdfButton offerId={offer.id} offerNo={offer.offer_no} revisionNo={offer.revision_no} />
            {offer.status === "taslak" && canUpdate && (
              <Link href={`/teklifler/${offer.id}/duzenle`}>
                <Button variant="secondary">Düzenle</Button>
              </Link>
            )}
            {project ? (
              <Link href={`/projeler/${project.id}`}>
                <Button variant="secondary">Projeyi Görüntüle</Button>
              </Link>
            ) : (
              offer.status === "kabul edildi" && canCreateProject && !projectAccessDenied && (
                <Link href={`/teklifler/${offer.id}/projeye-donustur`}>
                  <Button>Projeye Dönüştür</Button>
                </Link>
              )
            )}
            <OfferActions offer={offer} />
          </div>
        }
      />
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
                  {hasInternalPricing && (
                    <>
                      <Th className="text-right text-gold">İç Maliyet</Th>
                      <Th className="text-right text-gold">Beklenen Kâr</Th>
                    </>
                  )}
                </tr>
              </thead>
              <tbody>
                {offer.items?.map((it) => (
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

          <ActivityTimeline events={events} emailLogs={email_logs} revisionNoById={revisionNoById} />
        </div>

        <div className="flex w-full flex-col gap-6 lg:w-80">
          <Card className="h-fit">
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
              <div className="mt-3 border-t border-border pt-3 text-xs uppercase tracking-widest text-text-muted">
                Geçerlilik Tarihi
              </div>
              <div>
                {offer.valid_until ? new Date(offer.valid_until).toLocaleDateString("tr-TR") : "Süresiz"}
              </div>
            </CardBody>
          </Card>

          <ShareOfferCard offer={offer} links={share_links} revisionNoById={revisionNoById} />

          {revisions.length > 1 && (
            <Card className="h-fit">
              <CardHeader>Revizyon Geçmişi</CardHeader>
              <CardBody className="flex flex-col gap-2 p-0">
                {revisions.map((rev) => (
                  <Link
                    key={rev.id}
                    href={`/teklifler/${offer.id}/revizyonlar/${rev.id}`}
                    className="flex items-center justify-between border-b border-border px-4 py-3 text-sm last:border-b-0 hover:bg-surface-hover"
                  >
                    <div>
                      <div className="flex items-center gap-2 font-medium">
                        Revizyon {rev.revision_no}
                        {rev.revision_no === offer.revision_no && (
                          <span className="text-xs text-gold">(güncel)</span>
                        )}
                        <StatusBadge status={rev.status} registry={OFFER_STATUS} />
                      </div>
                      <div className="text-xs text-text-muted">
                        {new Date(rev.created_at).toLocaleString("tr-TR")}
                      </div>
                    </div>
                    <div className="font-medium">{formatTL(rev.grand_total)}</div>
                  </Link>
                ))}
              </CardBody>
            </Card>
          )}
        </div>
      </div>
    </>
  );
}

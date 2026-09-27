import { ExternalLink } from "lucide-react";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatTL } from "@/lib/format";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import { changePercentOf, formatChangeTime, reasonLabel } from "@/lib/price-changes";
import {
  formatSyncTime,
  isMissingFromSource,
  PRICE_SOURCES_PATH,
  siteHost,
  sourceAttribution,
  sourceLabels,
} from "@/lib/price-sources";
import type { PriceHistoryEntry, PriceSource, Product } from "@/lib/types";

import { ChangePercent, SourceBadge } from "../PriceChangeBits";
import { EditProductForm } from "./EditProductForm";

export default async function UrunDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.products);
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const canManage = canAccess(me, "products.manage");
  // Ürün, fiyat geçmişi ve fiyat kaynağı uçlarının üçü de yalnızca
  // products.read ister (router.go) -- yukarıdaki kapı hepsini garanti eder.
  // Fiyat kaynağı yalnızca "listede yok" rozeti ve kaynak bilgisi için;
  // hatası sayfayı düşürmez.
  const [product, historyRes, priceSources] = await Promise.all([
    apiServer<Product>(`/api/v1/products/${id}`, cookieHeader),
    apiServer<{ history: PriceHistoryEntry[] }>(
      `/api/v1/products/${id}/price-history`,
      cookieHeader
    ),
    apiServer<{ sources: PriceSource[] }>(PRICE_SOURCES_PATH, cookieHeader)
      .then((r) => r.sources)
      .catch(() => null),
  ]);
  const ps = product.source ? (priceSources?.find((s) => s.source === product.source) ?? null) : null;
  const labels = product.source ? sourceLabels(product.source, ps?.name) : null;
  // Fiyat kaynağı alınamadıysa false: ad/birim kilidi güvenli tarafta kalır.
  const missing = isMissingFromSource(product, ps);
  // Demir Profil'in kullanım koşulu kaynağın (ve liste ayının) belirtilmesini
  // istiyor; kaynak bilgisi alınamasa da en azından site adı yazılır.
  const attribution = product.source ? sourceAttribution(product.source, ps) : "";

  return (
    <>
      <PageHeader title={product.name} />
      <div className="flex max-w-md flex-col gap-6 p-4 sm:p-8">
        <Card>
          <CardHeader className="flex flex-wrap items-center justify-between gap-3">
            <span>Fiyat Kaynağı</span>
            <div className="flex flex-wrap justify-end gap-2">
              {product.source ? (
                <SourceBadge source={product.source} name={ps?.name} />
              ) : (
                <Badge tone="muted">Elle eklendi</Badge>
              )}
              {labels && missing && <Badge tone="danger">{labels.short} listesinde yok</Badge>}
            </div>
          </CardHeader>
          <CardBody className="flex flex-col gap-2 text-sm">
            {labels ? (
              <>
                <p className="text-text-muted">
                  Bu ürünün fiyatı ve kategorisi her {labels.short} güncellemesinde {labels.short} fiyat
                  listesinden yeniden yazılır; elle yapılan fiyat ve kategori değişiklikleri bir sonraki
                  güncellemede kaybolur.
                  {canManage && " Satış fiyatını kalıcı değiştirmek için Ürünler sayfasındaki kâr oranı ayarlarını kullanın."}
                </p>
                {/* Backend (matchSourceRows) kaynak satırlarını boşlukları
                    sadeleştirilmiş (ad, birim) ile eşleştirir -- büyük/küçük harf dahil. */}
                <p className="text-text-muted">
                  Ürün, {labels.short} listesiyle adı ve birimi üzerinden eşleşir. Ad veya birim değişirse bağlantı
                  kopar: bir sonraki güncelleme {labels.short} ürününü yeni bir kayıt olarak ekler, bu kayıt da
                  &quot;{labels.short} listesinde yok&quot; olarak kalır ve fiyatı artık güncellenmez.
                </p>
                {/* Kâr oranı uygulanmamış fiyat: backend yalnızca products.manage'e döndürür. */}
                {canManage && typeof product.source_price === "number" && (
                  <div className="flex justify-between gap-3">
                    <span className="text-text-muted">{labels.short} fiyatı</span>
                    <span className="font-medium">{formatTL(product.source_price)}</span>
                  </div>
                )}
                <div className="flex justify-between gap-3">
                  <span className="text-text-muted">{labels.short} listesinde son görülme</span>
                  <span className="text-right font-medium">
                    {product.source_synced_at ? formatSyncTime(product.source_synced_at) : "Henüz güncellenmedi"}
                  </span>
                </div>
                {ps?.vat_note && (
                  <div className="flex justify-between gap-3">
                    <span className="shrink-0 text-text-muted">Fiyat esası</span>
                    <span className="text-right">{ps.vat_note}</span>
                  </div>
                )}
                {(attribution || ps?.site_url.startsWith("https://")) && (
                  <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 border-t border-border pt-2 text-xs text-text-muted">
                    <span>{attribution}</span>
                    {ps?.site_url.startsWith("https://") && (
                      <a
                        href={ps.site_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="inline-flex items-center gap-1 font-medium text-gold hover:underline"
                      >
                        {siteHost(ps.site_url)}
                        <ExternalLink size={12} strokeWidth={2} aria-hidden />
                      </a>
                    )}
                  </div>
                )}
              </>
            ) : (
              <p className="text-text-muted">
                Elle eklenen ürün: tedarikçi güncellemeleri (Ulaş, Demir Profil) bu ürünün fiyatına dokunmaz.
              </p>
            )}
          </CardBody>
        </Card>

        <EditProductForm
          product={product}
          canManage={canManage}
          sourceLink={labels ? (missing ? "missing" : "linked") : "none"}
          sourceName={labels?.short ?? ""}
        />

        {historyRes.history.length > 0 && (
          <Card>
            <CardHeader>Fiyat Geçmişi</CardHeader>
            <CardBody className="flex flex-col divide-y divide-border py-0">
              {historyRes.history.map((h, i) => (
                <div key={i} className="flex flex-col gap-1 py-3 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                    <span className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">{reasonLabel(h.reason, h.old_price, h.new_price)}</span>
                      {h.source && <SourceBadge source={h.source} />}
                    </span>
                    <ChangePercent
                      oldPrice={h.old_price}
                      newPrice={h.new_price}
                      percent={changePercentOf(h.old_price, h.new_price)}
                    />
                  </div>
                  <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-text-muted">
                    <span>{formatChangeTime(h.changed_at)}</span>
                    <span className="whitespace-nowrap">
                      {formatTL(h.old_price)} → <span className="font-medium text-text">{formatTL(h.new_price)}</span>
                    </span>
                  </div>
                  {/* Tedarikçi fiyatları yalnızca products.manage'e döner (diğerlerinde null). */}
                  {h.old_source_price !== null && h.new_source_price !== null && (
                    <div className="text-xs text-text-muted">
                      Tedarikçi fiyatı: {formatTL(h.old_source_price)} → {formatTL(h.new_source_price)}
                    </div>
                  )}
                  {h.note && <div className="text-xs text-text-muted">{h.note}</div>}
                </div>
              ))}
            </CardBody>
          </Card>
        )}
      </div>
    </>
  );
}

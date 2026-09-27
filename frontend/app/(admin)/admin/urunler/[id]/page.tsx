import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatTL } from "@/lib/format";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import { formatSyncTime, isMissingFromSource, PRICE_SOURCES_PATH, ULAS_SOURCE } from "@/lib/price-sources";
import type { PriceHistoryEntry, PriceSource, Product } from "@/lib/types";

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
  // Fiyat kaynağı yalnızca "listede yok" rozeti için; hatası sayfayı düşürmez.
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
  const isUlas = product.source === ULAS_SOURCE;
  const ulas = priceSources?.find((s) => s.source === ULAS_SOURCE) ?? null;
  // Fiyat kaynağı alınamadıysa false: ad/birim kilidi güvenli tarafta kalır.
  const missingFromUlas = isMissingFromSource(product, ulas);

  return (
    <>
      <PageHeader title={product.name} />
      <div className="flex max-w-md flex-col gap-6 p-8">
        <Card>
          <CardHeader className="flex items-center justify-between gap-3">
            <span>Fiyat Kaynağı</span>
            <div className="flex flex-wrap justify-end gap-2">
              {isUlas ? <Badge tone="info">Ulaş</Badge> : <Badge tone="muted">Elle eklendi</Badge>}
              {missingFromUlas && <Badge tone="danger">Ulaş listesinde yok</Badge>}
            </div>
          </CardHeader>
          <CardBody className="flex flex-col gap-2 text-sm">
            {isUlas ? (
              <>
                <p className="text-text-muted">
                  Bu ürünün fiyatı ve kategorisi her Ulaş güncellemesinde Ulaş fiyat listesinden yeniden
                  yazılır; elle yapılan fiyat ve kategori değişiklikleri bir sonraki güncellemede kaybolur.
                  {canManage && " Satış fiyatını kalıcı değiştirmek için Ürünler sayfasındaki kâr oranı ayarlarını kullanın."}
                </p>
                {/* Backend (matchSourceRows) Ulaş satırlarını boşlukları sadeleştirilmiş
                    (ad, birim) ile eşleştirir -- büyük/küçük harf dahil. */}
                <p className="text-text-muted">
                  Ürün, Ulaş listesiyle adı ve birimi üzerinden eşleşir. Ad veya birim değişirse bağlantı kopar:
                  bir sonraki güncelleme Ulaş ürününü yeni bir kayıt olarak ekler, bu kayıt da &quot;Ulaş listesinde
                  yok&quot; olarak kalır ve fiyatı artık güncellenmez.
                </p>
                {/* Kâr oranı uygulanmamış fiyat: backend yalnızca products.manage'e döndürür. */}
                {canManage && typeof product.source_price === "number" && (
                  <div className="flex justify-between">
                    <span className="text-text-muted">Ulaş fiyatı</span>
                    <span className="font-medium">{formatTL(product.source_price)}</span>
                  </div>
                )}
                <div className="flex justify-between">
                  <span className="text-text-muted">Ulaş listesinde son görülme</span>
                  <span className="font-medium">
                    {product.source_synced_at ? formatSyncTime(product.source_synced_at) : "Henüz güncellenmedi"}
                  </span>
                </div>
              </>
            ) : (
              <p className="text-text-muted">
                Elle eklenen ürün: Ulaş güncellemeleri bu ürünün fiyatına dokunmaz.
              </p>
            )}
          </CardBody>
        </Card>

        <EditProductForm
          product={product}
          canManage={canManage}
          sourceLink={isUlas ? (missingFromUlas ? "missing" : "linked") : "none"}
        />

        {historyRes.history.length > 0 && (
          <Card>
            <CardHeader>Fiyat Geçmişi</CardHeader>
            <CardBody className="flex flex-col gap-2">
              {historyRes.history.map((h, i) => (
                <div
                  key={i}
                  className="flex justify-between gap-3 text-sm text-text-muted"
                >
                  <span>
                    {new Date(h.changed_at).toLocaleDateString("tr-TR")}
                    {h.note && <span className="block text-xs">{h.note}</span>}
                  </span>
                  <span>
                    {formatTL(h.old_price)} → {formatTL(h.new_price)}
                  </span>
                </div>
              ))}
            </CardBody>
          </Card>
        )}
      </div>
    </>
  );
}

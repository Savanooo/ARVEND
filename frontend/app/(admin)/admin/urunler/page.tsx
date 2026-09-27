import { ChevronLeft, ChevronRight } from "lucide-react";
import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatTL } from "@/lib/format";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import { isMissingFromSource, PRICE_SOURCES_PATH, ULAS_SOURCE } from "@/lib/price-sources";
import type { PriceSource, Product } from "@/lib/types";

import { PriceSourceCard } from "./PriceSourceCard";

// Backend (ProductService.List) sayfa başına en fazla 200 ürün döndürür;
// eskiden limit gönderilmediği için yalnızca ilk 50 ürün görünüyordu (Ulaş
// senkronundan sonra katalog ~630 ürün).
const PAGE_SIZE = 100;
// Backend OFFSET'i int32 hesaplar -- uçuk bir ?page= taşıp 500'e dönmesin.
const MAX_PAGE = 1_000_000;

function parsePage(raw: string | undefined): number {
  const n = Math.floor(Number(raw));
  if (!Number.isFinite(n) || n < 1) return 1;
  return Math.min(n, MAX_PAGE);
}

export default async function UrunlerPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; page?: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.products);
  const sp = await searchParams;
  const q = sp.q ?? "";
  const page = parsePage(sp.page);
  // "Ürün kataloğunu görüntüleme" teklif hazırlarken ürün seçebilmek için de
  // verilir: ekleme/düzenleme yalnızca "Ürün kataloğunu düzenleme" ile.
  const canManage = canAccess(me, "products.manage");

  const cookieHeader = (await cookies()).toString();
  const query = new URLSearchParams({ page: String(page), limit: String(PAGE_SIZE) });
  if (q) query.set("q", q);
  // Fiyat kaynağı ucu da yalnızca products.read ister (router.go); yine de
  // bir hata ürün listesini düşürmesin -- kart "alınamadı" der, "listede
  // yok" rozetleri gösterilmez.
  const [{ products, total }, priceSources] = await Promise.all([
    apiServer<{ products: Product[]; total: number }>(`/api/v1/products?${query.toString()}`, cookieHeader),
    apiServer<{ sources: PriceSource[] }>(PRICE_SOURCES_PATH, cookieHeader)
      .then((r) => r.sources)
      .catch(() => null),
  ]);
  const ulas = priceSources?.find((s) => s.source === ULAS_SOURCE) ?? null;

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  function pageHref(target: number) {
    const params = new URLSearchParams();
    if (q) params.set("q", q);
    if (target > 1) params.set("page", String(target));
    const s = params.toString();
    return s ? `/admin/urunler?${s}` : "/admin/urunler";
  }

  // Ulaş fiyatı (kâr oranı uygulanmamış) yalnızca products.manage sahibine
  // gelir; diğerlerinde backend source_price'ı null döndürür.
  const showSourcePrice = canManage;
  const columnCount = showSourcePrice ? 6 : 5;

  return (
    <>
      <PageHeader
        title="Ürünler"
        action={
          canManage ? (
            <Link href="/admin/urunler/yeni">
              <Button>+ Yeni Ürün</Button>
            </Link>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <PriceSourceCard priceSource={ulas} canManage={canManage} />

        {/* Aramada ?page= gönderilmez: yeni arama her zaman 1. sayfadan başlar. */}
        <form className="max-w-xs">
          <Input
            name="q"
            defaultValue={q}
            placeholder="Ürün adında ara…"
          />
        </form>
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Ürün</Th>
                <Th>Birim</Th>
                <Th>Kategori</Th>
                {showSourcePrice && <Th className="text-right">Ulaş fiyatı</Th>}
                <Th className="text-right">Birim Fiyat</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {products.map((p) => (
                <Tr key={p.id}>
                  <Td className="font-medium">
                    <div className="flex flex-wrap items-center gap-2">
                      <span>{p.name}</span>
                      {p.source === ULAS_SOURCE && <Badge tone="info">Ulaş</Badge>}
                      {isMissingFromSource(p, ulas) && <Badge tone="danger">Ulaş listesinde yok</Badge>}
                    </div>
                  </Td>
                  <Td className="text-text-muted">{p.unit}</Td>
                  <Td className="text-text-muted">{p.category || "—"}</Td>
                  {showSourcePrice && (
                    <Td className="text-right text-text-muted">
                      {typeof p.source_price === "number" ? formatTL(p.source_price) : "—"}
                    </Td>
                  )}
                  <Td className="text-right font-medium">
                    {formatTL(p.unit_price)}
                  </Td>
                  <Td className="text-right">
                    <Link
                      href={`/admin/urunler/${p.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      {canManage ? "Düzenle" : "Görüntüle"}
                    </Link>
                  </Td>
                </Tr>
              ))}
              {products.length === 0 && (
                <tr>
                  <Td colSpan={columnCount} className="text-center text-text-muted">
                    {total > 0 ? "Bu sayfada ürün yok." : "Ürün bulunamadı."}
                  </Td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
        <div className="flex items-center justify-between text-xs text-text-muted">
          <span>
            Toplam {total} ürün · Sayfa {page} / {totalPages}
          </span>
          <div className="flex items-center gap-3">
            {page > 1 && (
              // Son sayfanın ötesine elle gidildiyse "Önceki" son sayfaya döner.
              <Link href={pageHref(Math.min(page - 1, totalPages))} className="flex items-center gap-1 hover:text-gold">
                <ChevronLeft size={14} strokeWidth={1.75} />
                Önceki
              </Link>
            )}
            {page < totalPages && (
              <Link href={pageHref(page + 1)} className="flex items-center gap-1 hover:text-gold">
                Sonraki
                <ChevronRight size={14} strokeWidth={1.75} />
              </Link>
            )}
          </div>
        </div>
      </div>
    </>
  );
}

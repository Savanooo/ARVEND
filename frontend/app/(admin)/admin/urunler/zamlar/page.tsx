import { ArrowLeft } from "lucide-react";
import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Pagination } from "@/components/ui/Pagination";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiServer, ApiError } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatSignedMoney, formatTL } from "@/lib/format";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import {
  CHANGES_ANCHOR,
  changesTitle,
  clearEventHref,
  eventAvgTone,
  eventCountsText,
  eventHref,
  eventReasonLabel,
  eventScopeLabel,
  eventTimeLabel,
  formatChangePercent,
  formatChangeTime,
  formatDayRange,
  hasSourcePrices,
  isSelectedEvent,
  istanbulDay,
  listQuery,
  parseZamlarParams,
  PRICE_CHANGES_PAGE_SIZE,
  PRICE_CHANGES_PATH,
  PRICE_CHANGES_SUMMARY_PATH,
  reasonFilterLabel,
  reasonLabel,
  resolvePeriod,
  summaryQuery,
  zamlarHref,
} from "@/lib/price-changes";
import { attributionsFor, formatPercent, KNOWN_SOURCES, PRICE_SOURCES_PATH, sourceLabels } from "@/lib/price-sources";
import type { PriceChangeList, PriceChangeSummary, PriceSource } from "@/lib/types";

import { CHANGE_TONE_CLASS, ChangePercent, changeToneClass, SourceBadge } from "../PriceChangeBits";
import { PriceChangeFilters } from "./PriceChangeFilters";

// Backend en fazla bu kadar olay döner (maxPriceChangeEvents).
const MAX_EVENTS = 1000;

type Loaded<T> = { ok: true; data: T } | { ok: false; error: string };

/**
 * Filtre hatası (400: ör. elle yazılmış bozuk bir olay aralığı) sayfayı
 * düşürmesin, bölümün yerinde gösterilsin. Diğer hatalar diğer sayfalardaki
 * gibi yukarı fırlar.
 */
async function loadOr400<T>(request: Promise<T>): Promise<Loaded<T>> {
  try {
    return { ok: true, data: await request };
  } catch (err) {
    if (err instanceof ApiError && err.status === 400) return { ok: false, error: err.message };
    throw err;
  }
}

function StatCard({
  label,
  value,
  valueClassName = "",
  detail,
}: {
  label: string;
  value: React.ReactNode;
  valueClassName?: string;
  detail?: React.ReactNode;
}) {
  return (
    <Card className="min-w-0">
      <CardBody className="flex flex-col gap-1">
        <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">{label}</span>
        <span className={`text-2xl font-bold ${valueClassName}`}>{value}</span>
        {detail && <span className="truncate text-xs text-text-muted">{detail}</span>}
      </CardBody>
    </Card>
  );
}

function ErrorNote({ children }: { children: React.ReactNode }) {
  return <p className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">{children}</p>;
}

/**
 * Zam Geçmişi: tedarikçi listelerinden (Ulaş, Demir Profil), kâr oranı
 * değişikliklerinden ve elle düzenlemelerden gelen fiyat değişiklikleri.
 * Yalnızca okuma: products.read yeter (Ürünler'i gören herkes). Tedarikçi
 * (maliyet) fiyatlarını backend yalnızca products.manage sahibine döndürür;
 * sütunlar da yalnızca API döndürdüyse görünür.
 */
export default async function ZamlarPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePagePermission(PAGE_PERMISSIONS.products);
  const params = parseZamlarParams(await searchParams);
  const range = resolvePeriod(params, istanbulDay(new Date()));
  const cookieHeader = (await cookies()).toString();

  const [summaryRes, listRes, priceSources] = await Promise.all([
    loadOr400(
      apiServer<PriceChangeSummary>(`${PRICE_CHANGES_SUMMARY_PATH}?${summaryQuery(params, range)}`, cookieHeader)
    ),
    loadOr400(apiServer<PriceChangeList>(`${PRICE_CHANGES_PATH}?${listQuery(params, range)}`, cookieHeader)),
    // Yalnızca kaynak adları ve kategori önerileri için; hatası sayfayı düşürmez.
    apiServer<{ sources: PriceSource[] }>(PRICE_SOURCES_PATH, cookieHeader)
      .then((r) => r.sources)
      .catch(() => null),
  ]);

  const sourceByCode = new Map((priceSources ?? []).map((s) => [s.source, s]));
  const sourceName = (code: string) => sourceLabels(code, sourceByCode.get(code)?.name).short;
  const sourceOptions = (priceSources?.map((s) => s.source) ?? KNOWN_SOURCES).map((code) => ({
    code,
    name: sourceName(code),
  }));
  const categories = [
    ...new Set([
      ...(priceSources ?? []).flatMap((s) => s.categories.map((c) => c.category)),
      ...(listRes.ok ? listRes.data.changes.map((c) => c.category) : []),
    ]),
  ]
    .filter(Boolean)
    .sort((a, b) => a.localeCompare(b, "tr"));

  const summary = summaryRes.ok ? summaryRes.data : null;
  const list = listRes.ok ? listRes.data : null;
  const showSourcePrices = list ? hasSourcePrices(list.changes) : false;
  const columnCount = showSourcePrices ? 7 : 6;
  const totalPages = list ? Math.max(1, Math.ceil(list.total / PRICE_CHANGES_PAGE_SIZE)) : 1;

  // Demir Profil'in kullanım koşulu: fiyatlarının gösterildiği her yerde
  // kaynak ve liste ayı belirtilir (kart ve ürün detayı gibi).
  const attributions = attributionsFor(
    [
      params.source,
      params.event?.source,
      ...(list?.changes.map((c) => c.source) ?? []),
      ...(summary?.events.map((ev) => ev.source) ?? []),
    ],
    priceSources
  );

  const context = [
    `${range.label} (${formatDayRange(range.from, range.to)})`,
    params.source ? sourceName(params.source) : "Tüm kaynaklar",
    reasonFilterLabel(params.reason),
  ].join(" · ");

  const emptyText =
    list && list.total > 0
      ? "Bu sayfada kayıt yok."
      : params.direction === "up"
        ? "Bu filtrelerle zam gelen ürün yok."
        : params.direction === "down"
          ? "Bu filtrelerle indirim gelen ürün yok."
          : "Bu filtrelerle fiyatı değişen ürün yok.";

  return (
    <>
      <PageHeader
        title="Zam Geçmişi"
        action={
          <Link href="/admin/urunler">
            <Button variant="secondary">
              <ArrowLeft size={14} strokeWidth={2} />
              Ürünler
            </Button>
          </Link>
        }
      />
      <div className="flex min-w-0 flex-col gap-6 p-4 sm:p-8">
        <PriceChangeFilters
          key={zamlarHref(params)}
          params={params}
          range={range}
          sources={sourceOptions}
          categories={categories}
        />
        {range.error && <ErrorNote>{range.error}</ErrorNote>}

        {/* Özet: dönem + kaynak + neden (yön/kategori/arama tabloya özgü). */}
        <section aria-label="Özet" className="flex flex-col gap-2">
          <p className="text-xs text-text-muted">{context}</p>
          {summary ? (
            <div className="grid grid-cols-1 gap-3 min-[420px]:grid-cols-2 lg:grid-cols-4">
              <StatCard
                label="Zam gelen ürün"
                value={summary.products_increased}
                valueClassName={summary.products_increased > 0 ? "text-danger" : ""}
                detail={
                  summary.increased_count !== summary.products_increased
                    ? `${summary.increased_count} zam kaydı`
                    : undefined
                }
              />
              <StatCard
                label="Ortalama zam"
                value={summary.avg_increase_percent === null ? "—" : formatPercent(summary.avg_increase_percent)}
                valueClassName={summary.avg_increase_percent ? "text-danger" : ""}
              />
              <StatCard
                label="En yüksek zam"
                value={summary.max_increase ? formatPercent(summary.max_increase.change_percent) : "—"}
                valueClassName={summary.max_increase ? "text-danger" : ""}
                detail={
                  summary.max_increase ? (
                    <Link
                      href={`/admin/urunler/${summary.max_increase.product_id}`}
                      className="hover:text-gold hover:underline"
                      title={summary.max_increase.product_name}
                    >
                      {summary.max_increase.product_name}
                    </Link>
                  ) : undefined
                }
              />
              <StatCard
                label="İndirim"
                value={summary.decreased_count}
                valueClassName={summary.decreased_count > 0 ? "text-success" : ""}
                detail={summary.decreased_count > 0 ? "fiyatı düşen değişiklik" : undefined}
              />
            </div>
          ) : (
            <ErrorNote>Özet alınamadı: {summaryRes.ok ? "" : summaryRes.error}</ErrorNote>
          )}
        </section>

        {/* Zaman çizelgesi: her senkron / kâr oranı güncellemesi bir olay,
            elle düzenlemeler gün başına. Olaya tıklamak tabloyu o olayın
            satırlarına daraltır. */}
        <section aria-labelledby="zam-gecmisi-baslik">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-2">
              <span id="zam-gecmisi-baslik">Zam Geçmişi</span>
              {summary && (
                <span className="font-normal normal-case tracking-normal">
                  {summary.events.length} güncelleme
                </span>
              )}
            </CardHeader>
            {!summary ? (
              <CardBody className="text-sm text-text-muted">Güncellemeler alınamadı.</CardBody>
            ) : summary.events.length === 0 ? (
              <CardBody className="text-sm text-text-muted">Bu dönemde fiyat güncellemesi yok.</CardBody>
            ) : (
              <>
                <ol className="max-h-80 divide-y divide-border overflow-y-auto">
                  {summary.events.map((ev) => {
                    const selected = isSelectedEvent(params.event, ev);
                    const avg = ev.avg_change_percent;
                    const avgTone = eventAvgTone(ev);
                    return (
                      <li
                        key={`${ev.changed_at}|${ev.source ?? ""}|${ev.reason}`}
                        className={`flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-5 py-3 ${
                          selected ? "bg-gold-soft" : ""
                        }`}
                      >
                        <div className="flex min-w-0 flex-col gap-1">
                          <div className="flex flex-wrap items-center gap-2 text-sm">
                            <span className="font-medium">{eventTimeLabel(ev)}</span>
                            {ev.source && <SourceBadge source={ev.source} name={sourceByCode.get(ev.source)?.name} />}
                            <span className="text-xs text-text-muted">{eventReasonLabel(ev.reason)}</span>
                          </div>
                          <div className="text-sm text-text-muted">
                            {eventCountsText(ev)}
                            {avg !== null && (
                              <>
                                {" · ort. "}
                                <span className={`font-semibold ${CHANGE_TONE_CLASS[avgTone]}`}>
                                  {formatChangePercent(avg, avgTone)}
                                </span>
                              </>
                            )}
                            {ev.max_increase_percent !== null && ev.increased > 1 && (
                              <> · en yüksek zam {formatPercent(ev.max_increase_percent)}</>
                            )}
                          </div>
                        </div>
                        <Link
                          href={eventHref(params, ev)}
                          aria-current={selected ? "true" : undefined}
                          className="shrink-0 text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                        >
                          {selected ? "Tabloda gösteriliyor" : "Ürünleri gör"}
                        </Link>
                      </li>
                    );
                  })}
                </ol>
                {summary.events.length >= MAX_EVENTS && (
                  <p className="border-t border-border px-5 py-3 text-xs text-text-muted">
                    En yeni {MAX_EVENTS} güncelleme gösteriliyor; daha eskileri için dönemi daraltın.
                  </p>
                )}
              </>
            )}
          </Card>
        </section>

        {/* Zam gelen ürünler tablosu -- olay ve sayfa bağlantıları buraya iner. */}
        <section id={CHANGES_ANCHOR} className="flex scroll-mt-4 flex-col gap-3">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 className="text-base font-bold tracking-tight">{changesTitle(params.direction)}</h2>
            {list && <span className="text-xs text-text-muted">{list.total} kayıt</span>}
          </div>
          {params.event && (
            <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 rounded-md bg-info-soft px-3 py-2 text-sm text-info">
              <span>
                Yalnızca bu güncellemenin değişiklikleri: <strong>{eventScopeLabel(params.event)}</strong>
              </span>
              <Link href={clearEventHref(params)} className="font-semibold hover:underline">
                Tüm dönemi göster
              </Link>
            </div>
          )}
          {list ? (
            <>
              <Card>
                <Table>
                  <thead>
                    <tr>
                      <Th>Ürün</Th>
                      <Th>Kaynak</Th>
                      <Th className="text-right">Eski → Yeni fiyat</Th>
                      <Th className="text-right">Fark</Th>
                      <Th className="text-right">Değişim</Th>
                      {showSourcePrices && <Th className="text-right">Tedarikçi fiyatı</Th>}
                      <Th>Tarih</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {list.changes.map((c) => (
                      <Tr key={c.id}>
                        <Td className="min-w-[16rem]">
                          <Link
                            href={`/admin/urunler/${c.product_id}`}
                            className="font-medium hover:text-gold hover:underline"
                          >
                            {c.product_name}
                          </Link>
                          <div className="text-xs text-text-muted">{[c.unit, c.category].filter(Boolean).join(" · ")}</div>
                        </Td>
                        <Td>
                          <div className="flex flex-col items-start gap-1">
                            {c.source && <SourceBadge source={c.source} name={sourceByCode.get(c.source)?.name} />}
                            <span className="whitespace-nowrap text-xs text-text-muted">
                              {reasonLabel(c.reason, c.old_price, c.new_price)}
                            </span>
                          </div>
                        </Td>
                        <Td className="whitespace-nowrap text-right">
                          <span className="text-text-muted">{formatTL(c.old_price)}</span>
                          {" → "}
                          <span className="font-medium">{formatTL(c.new_price)}</span>
                        </Td>
                        <Td
                          className={`whitespace-nowrap text-right font-medium ${changeToneClass(c.old_price, c.new_price)}`}
                        >
                          {formatSignedMoney(c.change_amount)}
                        </Td>
                        <Td className="text-right">
                          <ChangePercent oldPrice={c.old_price} newPrice={c.new_price} percent={c.change_percent} />
                        </Td>
                        {showSourcePrices && (
                          <Td className="whitespace-nowrap text-right text-text-muted">
                            {c.old_source_price !== null && c.new_source_price !== null
                              ? `${formatTL(c.old_source_price)} → ${formatTL(c.new_source_price)}`
                              : "—"}
                          </Td>
                        )}
                        <Td className="whitespace-nowrap text-text-muted">{formatChangeTime(c.changed_at)}</Td>
                      </Tr>
                    ))}
                    {list.changes.length === 0 && (
                      <tr>
                        <Td colSpan={columnCount} className="text-center text-text-muted">
                          {emptyText}
                        </Td>
                      </tr>
                    )}
                  </tbody>
                </Table>
              </Card>
              <Pagination
                page={params.page}
                totalPages={totalPages}
                total={list.total}
                itemLabel="kayıt"
                hrefForPage={(n) => zamlarHref({ ...params, page: Math.min(n, totalPages) }, CHANGES_ANCHOR)}
              />
            </>
          ) : (
            <ErrorNote>Liste alınamadı: {listRes.ok ? "" : listRes.error}</ErrorNote>
          )}
        </section>

        {attributions.length > 0 && (
          <div className="flex flex-col gap-1 text-xs text-text-muted">
            {attributions.map((text) => (
              <p key={text}>{text}</p>
            ))}
          </div>
        )}
      </div>
    </>
  );
}

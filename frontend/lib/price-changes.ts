// Zam Geçmişi ekranının (/admin/urunler/zamlar) ve ürün fiyat geçmişinin
// saf yardımcıları -- next/* ya da React içermez; sayfa, istemci filtreleri
// ve node testleri (price-changes.test.mts) içe aktarır. Uçlar (backend
// price_change_handler.go): GET /api/v1/products/price-changes ve
// /price-changes/summary; ikisi de yalnızca products.read ister.
import { formatPercent, sourceLabels } from "./price-sources.ts";
import type { PriceChange, PriceChangeEvent, PriceChangeReason, PriceSource } from "./types";

export const PRICE_CHANGES_PATH = "/api/v1/products/price-changes";
export const PRICE_CHANGES_SUMMARY_PATH = `${PRICE_CHANGES_PATH}/summary`;
export const ZAMLAR_PATH = "/admin/urunler/zamlar";
// Tablo bölümünün id'si: olay ve sayfa bağlantıları doğrudan tabloya iner.
export const CHANGES_ANCHOR = "zam-gelen-urunler";

export const PRICE_CHANGES_PAGE_SIZE = 50;
// Backend sınırları: maxPriceChangePage (üstü 400), maxPriceChangeQuery ve
// pricesource.MaxCategoryLen (100 karakterden uzun arama/kategori 400).
export const MAX_PRICE_CHANGES_PAGE = 100_000;
export const MAX_FILTER_TEXT = 100;

const ISTANBUL = "Europe/Istanbul";

// ---------- Tarih ----------

/**
 * Date.parse bazı tarayıcılarda 3'ten fazla kesirli saniye basamağını
 * (backend RFC3339Nano, mikrosaniye) okuyamaz; milisaniyeye kısaltılır.
 */
function parseTime(iso: string): number {
  return Date.parse(iso.replace(/(\.\d{3})\d+/, "$1"));
}

const dayKeyFormat = new Intl.DateTimeFormat("en-CA", {
  timeZone: ISTANBUL,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** Anın İstanbul takvim günü: 2026-09-26T21:30Z -> "2026-09-27". */
export function istanbulDay(at: Date): string {
  const parts: Record<string, string> = {};
  for (const p of dayKeyFormat.formatToParts(at)) parts[p.type] = p.value;
  return `${parts.year}-${parts.month}-${parts.day}`;
}

const DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

function dayParts(day: string): [number, number, number] | null {
  const m = DAY_RE.exec(day);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const t = new Date(Date.UTC(y, mo - 1, d));
  // "2026-02-30" gibi taşan günler ve 0-99 yılları (Date.UTC 1900'e çevirir) reddedilir.
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return null;
  return [y, mo, d];
}

/** Geçerli bir YYYY-AA-GG takvim günü mü? */
export function isValidDay(day: string): boolean {
  return dayParts(day) !== null;
}

/** Takvim günü aritmetiği (saat dilimi yok): addDays("2026-03-01", -1) -> "2026-02-28". */
export function addDays(day: string, n: number): string {
  const p = dayParts(day);
  if (!p) return day;
  return new Date(Date.UTC(p[0], p[1] - 1, p[2] + n)).toISOString().slice(0, 10);
}

const dayLabelFormat = new Intl.DateTimeFormat("tr-TR", {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

/** "2026-09-21" -> "21 Eylül 2026". */
export function formatDay(day: string): string {
  const p = dayParts(day);
  return p ? dayLabelFormat.format(Date.UTC(p[0], p[1] - 1, p[2])) : day;
}

export function formatDayRange(from: string, to: string): string {
  return from === to ? formatDay(from) : `${formatDay(from)} – ${formatDay(to)}`;
}

const istanbulDayLabelFormat = new Intl.DateTimeFormat("tr-TR", {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: ISTANBUL,
});

const istanbulTimeLabelFormat = new Intl.DateTimeFormat("tr-TR", {
  day: "numeric",
  month: "long",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZone: ISTANBUL,
});

const changeTimeFormat = new Intl.DateTimeFormat("tr-TR", {
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZone: ISTANBUL,
});

function formatWith(format: Intl.DateTimeFormat, iso: string): string {
  const t = parseTime(iso);
  return Number.isNaN(t) ? iso : format.format(t);
}

/** Tablo tarihi, İstanbul saatiyle: "27.09.2026 00:05". */
export function formatChangeTime(iso: string): string {
  return formatWith(changeTimeFormat, iso);
}

// ---------- Dönem ----------

export type PeriodKey = "7" | "30" | "90" | "yil" | "ozel";
type PresetPeriod = Exclude<PeriodKey, "ozel">;
export const DEFAULT_PERIOD: PresetPeriod = "30";

export const PERIOD_OPTIONS: readonly { key: PeriodKey; label: string }[] = [
  { key: "7", label: "Son 7 gün" },
  { key: "30", label: "Son 30 gün" },
  { key: "90", label: "Son 90 gün" },
  { key: "yil", label: "Bu yıl" },
  { key: "ozel", label: "Özel aralık" },
];

export interface ResolvedPeriod {
  // İstanbul günleri, ikisi de DAHİL (backend YYYY-AA-GG'yi böyle okur).
  from: string;
  to: string;
  label: string;
  // Özel aralık geçersizse varsayılan döneme dönülür ve bu açıklama gösterilir.
  error: string | null;
}

function presetPeriod(period: PresetPeriod, today: string): Omit<ResolvedPeriod, "error"> {
  if (period === "yil") return { from: `${today.slice(0, 4)}-01-01`, to: today, label: "Bu yıl" };
  const days = Number(period);
  // "Son 7 gün" = bugün + önceki 6 gün.
  return { from: addDays(today, -(days - 1)), to: today, label: `Son ${days} gün` };
}

/**
 * Seçili dönemin gün aralığı. today: İstanbul'un bugünü (istanbulDay).
 * Özel aralıkta bitiş boşsa bugün kullanılır.
 */
export function resolvePeriod(p: { period: PeriodKey; from: string; to: string }, today: string): ResolvedPeriod {
  if (p.period !== "ozel") return { ...presetPeriod(p.period, today), error: null };
  const to = p.to || today;
  const fallback = presetPeriod(DEFAULT_PERIOD, today);
  if (!p.from) return { ...fallback, error: "Özel aralık için başlangıç tarihi seçin; son 30 gün gösteriliyor." };
  if (!isValidDay(p.from) || !isValidDay(to)) return { ...fallback, error: "Tarih geçersiz; son 30 gün gösteriliyor." };
  if (p.from > to) {
    return { ...fallback, error: "Başlangıç tarihi bitiş tarihinden sonra olamaz; son 30 gün gösteriliyor." };
  }
  return { from: p.from, to, label: "Özel aralık", error: null };
}

// ---------- Filtreler (URL <-> backend sorgusu) ----------

export type DirectionFilter = "up" | "down" | "all";
export type ReasonFilter = PriceChangeReason | "all";
export type SortKey = "newest" | "largest_increase" | "largest_decrease";

export const DIRECTION_OPTIONS: readonly { value: DirectionFilter; label: string }[] = [
  { value: "up", label: "Zam" },
  { value: "down", label: "İndirim" },
  { value: "all", label: "Tümü" },
];

export const REASON_OPTIONS: readonly { value: ReasonFilter; label: string }[] = [
  { value: "supplier", label: "Tedarikçi fiyatı" },
  { value: "markup", label: "Kâr oranı" },
  { value: "manual", label: "Elle düzenleme" },
  { value: "all", label: "Tümü" },
];

export const SORT_OPTIONS: readonly { value: SortKey; label: string }[] = [
  { value: "newest", label: "En yeni" },
  { value: "largest_increase", label: "En yüksek zam" },
  { value: "largest_decrease", label: "En yüksek indirim" },
];

/**
 * Özetteki bir olayın (tek senkron / kâr oranı güncellemesi / elle
 * düzenleme günü) satırları. Tablo bu kapsamda olayın from/to, reason ve
 * source'unu kullanır (backend sözleşmesi: liste ucu bu dördüyle tam olarak
 * olayın satırlarını döner); dönem, kaynak ve neden seçimleri özet ile
 * zaman çizelgesi için geçerli kalır.
 */
export interface EventScope {
  from: string;
  to: string;
  reason: PriceChangeReason;
  // "" = kaynağı olmayan olay (elle düzenleme).
  source: string;
}

export interface ZamlarParams {
  period: PeriodKey;
  // Yalnızca period "ozel" iken (YYYY-AA-GG).
  from: string;
  to: string;
  // Özet, zaman çizelgesi ve tablo için; "" = tüm kaynaklar.
  source: string;
  reason: ReasonFilter;
  // Yalnızca tablo için.
  direction: DirectionFilter;
  category: string;
  q: string;
  sort: SortKey;
  page: number;
  event: EventScope | null;
}

export const DEFAULT_ZAMLAR_PARAMS: ZamlarParams = {
  period: DEFAULT_PERIOD,
  from: "",
  to: "",
  source: "",
  reason: "supplier",
  direction: "up",
  category: "",
  q: "",
  sort: "newest",
  page: 1,
  event: null,
};

type RawSearchParams = Record<string, string | string[] | undefined>;

function first(sp: RawSearchParams, key: string): string {
  const v = sp[key];
  return (Array.isArray(v) ? v[0] : v) ?? "";
}

function oneOf<T extends string>(value: string, allowed: readonly T[], fallback: T): T {
  return (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

const PERIOD_KEYS = PERIOD_OPTIONS.map((o) => o.key);
const REASONS: readonly PriceChangeReason[] = ["supplier", "markup", "manual"];
const REASON_FILTERS = REASON_OPTIONS.map((o) => o.value);
const DIRECTIONS = DIRECTION_OPTIONS.map((o) => o.value);
const SORTS = SORT_OPTIONS.map((o) => o.value);
// Kaynak kodu biçimi; hangi kodların geçerli olduğuna backend karar verir (400).
const SOURCE_CODE_RE = /^[a-z][a-z0-9_]{0,31}$/;
// Gruplar: saniyeye kadar tarih-saat, kesirli saniye (noktalı), saat dilimi.
const RFC3339_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;

/**
 * RFC3339(Nano) -> Unix mikrosaniye; bozuksa NaN. Date.parse milisaniyede
 * keser, olay aralıkları ise mikrosaniye hassasiyetindedir.
 */
function toMicros(iso: string): number {
  const m = RFC3339_RE.exec(iso);
  if (!m) return NaN;
  const ms = Date.parse(`${m[1]}${m[3]}`);
  const frac = (m[2] ?? ".").slice(1).padEnd(6, "0").slice(0, 6);
  return ms * 1000 + Number(frac);
}

/**
 * Arama/kategori metni: NUL baytı backend'de 400'dür, 100 karakterden
 * uzunu da. Kırpma kod noktası sayar (backend utf8.RuneCountInString).
 */
export function cleanFilterText(raw: string): string {
  const s = raw.split("\u0000").join("").trim();
  const chars = Array.from(s);
  return chars.length > MAX_FILTER_TEXT ? chars.slice(0, MAX_FILTER_TEXT).join("").trim() : s;
}

function parseSource(raw: string): string {
  return SOURCE_CODE_RE.test(raw) ? raw : "";
}

function parsePage(raw: string): number {
  if (!/^\d+$/.test(raw)) return 1;
  const n = Number(raw);
  return n >= 1 && n <= MAX_PRICE_CHANGES_PAGE ? n : 1;
}

/** Sayfanın URL parametrelerini okur; bilinmeyen/bozuk değerler varsayılana döner. */
export function parseZamlarParams(sp: RawSearchParams): ZamlarParams {
  const period = oneOf(first(sp, "period"), PERIOD_KEYS, DEFAULT_PERIOD);
  const eventFrom = first(sp, "event_from");
  const eventTo = first(sp, "event_to");
  const eventReason = first(sp, "event_reason");
  const event: EventScope | null =
    RFC3339_RE.test(eventFrom) && RFC3339_RE.test(eventTo) && (REASONS as readonly string[]).includes(eventReason)
      ? {
          from: eventFrom,
          to: eventTo,
          reason: eventReason as PriceChangeReason,
          source: parseSource(first(sp, "event_source")),
        }
      : null;
  return {
    period,
    from: period === "ozel" ? first(sp, "from").trim() : "",
    to: period === "ozel" ? first(sp, "to").trim() : "",
    source: parseSource(first(sp, "source")),
    reason: oneOf(first(sp, "reason"), REASON_FILTERS, DEFAULT_ZAMLAR_PARAMS.reason),
    direction: oneOf(first(sp, "direction"), DIRECTIONS, DEFAULT_ZAMLAR_PARAMS.direction),
    category: cleanFilterText(first(sp, "category")),
    q: cleanFilterText(first(sp, "q")),
    sort: oneOf(first(sp, "sort"), SORTS, DEFAULT_ZAMLAR_PARAMS.sort),
    page: parsePage(first(sp, "page")),
    event,
  };
}

/**
 * Sayfa bağlantısı; varsayılan değerler URL'e yazılmaz. parseZamlarParams
 * ile gidiş-dönüş kayıpsızdır.
 */
export function zamlarHref(p: ZamlarParams, anchor?: string): string {
  const d = DEFAULT_ZAMLAR_PARAMS;
  const q = new URLSearchParams();
  if (p.period !== d.period) q.set("period", p.period);
  if (p.period === "ozel") {
    if (p.from) q.set("from", p.from);
    if (p.to) q.set("to", p.to);
  }
  if (p.source) q.set("source", p.source);
  if (p.reason !== d.reason) q.set("reason", p.reason);
  if (p.direction !== d.direction) q.set("direction", p.direction);
  if (p.category) q.set("category", p.category);
  if (p.q) q.set("q", p.q);
  if (p.sort !== d.sort) q.set("sort", p.sort);
  if (p.page > 1) q.set("page", String(p.page));
  if (p.event) {
    q.set("event_from", p.event.from);
    q.set("event_to", p.event.to);
    q.set("event_reason", p.event.reason);
    if (p.event.source) q.set("event_source", p.event.source);
  }
  const s = q.toString();
  return `${ZAMLAR_PATH}${s ? `?${s}` : ""}${anchor ? `#${anchor}` : ""}`;
}

/** Filtre formunun alanları (istemci bileşeni PriceChangeFilters). */
export interface FilterForm {
  // Yalnızca özel aralıkta; diğer dönemlerde "".
  from: string;
  to: string;
  source: string;
  reason: ReasonFilter;
  direction: DirectionFilter;
  category: string;
  q: string;
  sort: SortKey;
}

/** Formun başlangıç değerleri; özel aralıkta tarihler ETKİN aralıkla dolar. */
export function filterFormFrom(p: ZamlarParams, range: Pick<ResolvedPeriod, "from" | "to">): FilterForm {
  const custom = p.period === "ozel";
  return {
    from: custom ? range.from : "",
    to: custom ? range.to : "",
    source: p.source,
    reason: p.reason,
    direction: p.direction,
    category: p.category,
    q: p.q,
    sort: p.sort,
  };
}

/**
 * Gönderilen formdan yeni parametreler; her zaman 1. sayfa. Seçili olay,
 * özetin bağlamı (tarih aralığı, kaynak, neden) değişmedikçe korunur -- yön,
 * kategori, arama ve sıralama olayın satırları içinde uygulanır.
 */
export function applyFilterForm(p: ZamlarParams, range: Pick<ResolvedPeriod, "from" | "to">, f: FilterForm): ZamlarParams {
  const initial = filterFormFrom(p, range);
  const custom = p.period === "ozel";
  const from = custom ? f.from : "";
  const to = custom ? f.to : "";
  const sameContext = from === initial.from && to === initial.to && f.source === p.source && f.reason === p.reason;
  return {
    ...p,
    from,
    to,
    source: f.source,
    reason: f.reason,
    direction: f.direction,
    category: cleanFilterText(f.category),
    q: cleanFilterText(f.q),
    sort: f.sort,
    page: 1,
    event: sameContext ? p.event : null,
  };
}

/**
 * Dönem bağlantısı: filtreler korunur, olay ve sayfa sıfırlanır (olay
 * bağlantısının koyduğu "tümü" yönü de, clearEventHref gibi, varsayılana
 * döner). Özel aralık etkin aralıkla başlar.
 */
export function periodHref(p: ZamlarParams, range: Pick<ResolvedPeriod, "from" | "to">, period: PeriodKey): string {
  const custom = period === "ozel";
  return zamlarHref({
    ...p,
    period,
    from: custom ? range.from : "",
    to: custom ? range.to : "",
    direction: p.event ? DEFAULT_ZAMLAR_PARAMS.direction : p.direction,
    page: 1,
    event: null,
  });
}

/** GET /price-changes sorgusu (tablo). Olay seçiliyse aralık, neden ve kaynak olayınkidir. */
export function listQuery(p: ZamlarParams, range: Pick<ResolvedPeriod, "from" | "to">): string {
  const q = new URLSearchParams();
  const scope = p.event ?? { from: range.from, to: range.to, reason: p.reason, source: p.source };
  q.set("from", scope.from);
  q.set("to", scope.to);
  q.set("reason", scope.reason);
  if (scope.source) q.set("source", scope.source);
  q.set("direction", p.direction);
  if (p.category) q.set("category", p.category);
  if (p.q) q.set("q", p.q);
  q.set("sort", p.sort);
  q.set("page", String(p.page));
  q.set("limit", String(PRICE_CHANGES_PAGE_SIZE));
  return q.toString();
}

/** GET /price-changes/summary sorgusu: dönem + kaynak + neden (yön/kategori/arama yok). */
export function summaryQuery(p: ZamlarParams, range: Pick<ResolvedPeriod, "from" | "to">): string {
  const q = new URLSearchParams({ from: range.from, to: range.to, reason: p.reason });
  if (p.source) q.set("source", p.source);
  return q.toString();
}

export function eventScope(ev: Pick<PriceChangeEvent, "from" | "to" | "reason" | "source">): EventScope {
  return { from: ev.from, to: ev.to, reason: ev.reason, source: ev.source ?? "" };
}

/**
 * Zaman çizelgesindeki olay, tabloda seçili kapsamın içinde mi (aynı neden
 * ve kaynak, aralığı kapsamın içinde)? Olay bağlantısı (eventHref) olayın
 * aralığını birebir taşır; fiyat kaynağı kartının bağlantısı
 * (sourceHistoryHref) senkronun saniyesini -- ikisi de olayı kapsar.
 */
export function isSelectedEvent(
  scope: EventScope | null,
  ev: Pick<PriceChangeEvent, "from" | "to" | "reason" | "source">
): boolean {
  if (!scope) return false;
  const other = eventScope(ev);
  if (scope.reason !== other.reason || scope.source !== other.source) return false;
  // Bozuk zamanda NaN karşılaştırması false döner.
  return toMicros(scope.from) <= toMicros(other.from) && toMicros(other.to) <= toMicros(scope.to);
}

/**
 * Zaman çizelgesindeki bir olayın bağlantısı: tablo olayın TÜM satırlarını
 * gösterir (yön "tümü", kategori/arama temizlenir); dönem, kaynak, neden ve
 * sıralama korunur.
 */
export function eventHref(p: ZamlarParams, ev: Pick<PriceChangeEvent, "from" | "to" | "reason" | "source">): string {
  return zamlarHref(
    { ...p, event: eventScope(ev), direction: "all", category: "", q: "", page: 1 },
    CHANGES_ANCHOR
  );
}

/** Olay kapsamını kaldırır; yön varsayılana (zam) döner. */
export function clearEventHref(p: ZamlarParams): string {
  return zamlarHref({ ...p, event: null, direction: DEFAULT_ZAMLAR_PARAMS.direction, page: 1 }, CHANGES_ANCHOR);
}

/**
 * Bir senkronun tedarikçi satırları. Backend satırları senkronun
 * last_synced_at'iyle (aynı transaction'ın now()'ı, mikrosaniyeli) yazar,
 * last_synced_at'i ise saniyeye kırparak (RFC3339) döndürür: kapsam o
 * saniyenin tamamıdır (liste ucu RFC3339 bitişi mikrosaniyesine kadar dahil
 * sayar). Aynı kaynağın senkronları kilitle sıralanır; iki fiyat değiştiren
 * senkronun aynı saniyeye düşmesi pratikte olmaz. Zaman bozuksa null.
 */
export function syncEventScope(source: string, syncedAt: string): EventScope | null {
  const m = RFC3339_RE.exec(syncedAt);
  if (!m || Number.isNaN(toMicros(syncedAt))) return null;
  if (m[2]) return { from: syncedAt, to: syncedAt, reason: "supplier", source };
  return { from: `${m[1]}${m[3]}`, to: `${m[1]}.999999${m[3]}`, reason: "supplier", source };
}

/**
 * Fiyat kaynağı kartındaki "Zam Geçmişi" bağlantısı. Kartın "Son
 * güncellemede N ürüne zam geldi" satırı son BAŞARILI senkronu anlatır, o
 * senkron ne kadar eski olursa olsun (otomatik güncelleme varsayılan
 * kapalı). Bu yüzden:
 * - dönem o senkronu kapsar: senkron günü varsayılan dönemin (son 30 gün)
 *   içindeyse varsayılan dönem, daha eskiyse senkron gününden bugüne özel
 *   aralık;
 * - senkron fiyat değiştirdiyse tablo doğrudan o senkronun satırlarını
 *   gösterir (syncEventScope; yön "tümü", olay bağlantısı gibi).
 * today: İstanbul'un bugünü (istanbulDay) -- sunucu sayfası verir, böylece
 * sunucu ve tarayıcı aynı bağlantıyı üretir.
 */
export function sourceHistoryHref(
  ps: Pick<PriceSource, "source" | "last_synced_at" | "last_changes">,
  today: string
): string {
  const base: ZamlarParams = { ...DEFAULT_ZAMLAR_PARAMS, source: ps.source };
  const scope = ps.last_synced_at ? syncEventScope(ps.source, ps.last_synced_at) : null;
  if (!scope) return zamlarHref(base);
  const syncDay = istanbulDay(new Date(parseTime(scope.from)));
  const inDefault = syncDay >= presetPeriod(DEFAULT_PERIOD, today).from;
  const period: ZamlarParams = inDefault ? base : { ...base, period: "ozel", from: syncDay, to: "" };
  const lc = ps.last_changes;
  if (!lc || lc.increased + lc.decreased === 0) return zamlarHref(period);
  return zamlarHref({ ...period, direction: "all", event: scope }, CHANGES_ANCHOR);
}

// ---------- Görüntüleme ----------

export type ChangeTone = "up" | "down" | "flat";

/** Fiyat artışı (zam) "up", düşüş (indirim) "down". */
export function changeTone(oldPrice: number, newPrice: number): ChangeTone {
  if (newPrice > oldPrice) return "up";
  if (newPrice < oldPrice) return "down";
  return "flat";
}

function toneOfPercent(pct: number | null): ChangeTone {
  return pct === null || pct === 0 ? "flat" : pct > 0 ? "up" : "down";
}

/**
 * "↑ %3,25" / "↓ %2,1" / "%0"; yüzde tanımsızsa (eski fiyat 0) "—". Ok
 * yüzdenin işaretinden değil fiyatın yönünden (tone, changeTone) gelir:
 * 250,00 → 250,01 TL backend'de %0'a yuvarlanır ama yine de zamdır
 * ("↑ <%0,01"). tone verilmezse yüzdenin işareti kullanılır.
 */
export function formatChangePercent(pct: number | null, tone: ChangeTone = toneOfPercent(pct)): string {
  if (pct === null) return "—";
  const abs = Math.abs(pct);
  // formatPercent 2 ondalık yazar: bunun altı "%0" görünürdü.
  const value = tone !== "flat" && Math.round(abs * 100) === 0 ? `<${formatPercent(0.01)}` : formatPercent(abs);
  if (tone === "up") return `↑ ${value}`;
  if (tone === "down") return `↓ ${value}`;
  return value;
}

/**
 * Zaman çizelgesindeki ortalama değişimin yönü. Ortalama %0'a yuvarlansa da
 * olayda yalnızca zam (ya da yalnızca indirim) varsa yön bellidir; zam ve
 * indirim birbirini götürdüyse "flat".
 */
export function eventAvgTone(ev: Pick<PriceChangeEvent, "avg_change_percent" | "increased" | "decreased">): ChangeTone {
  const avg = ev.avg_change_percent;
  if (avg !== null && avg !== 0) return avg > 0 ? "up" : "down";
  if (ev.increased > 0 && ev.decreased === 0) return "up";
  if (ev.decreased > 0 && ev.increased === 0) return "down";
  return "flat";
}

/**
 * (yeni - eski) / eski × 100, 2 ondalığa yarım-yukarı (sıfırdan uzağa)
 * yuvarlanmış -- backend changePercent ile aynı; eski fiyat 0 ise null.
 * Float hatası olmasın diye kuruş tamsayılarıyla hesaplanır.
 */
export function changePercentOf(oldPrice: number, newPrice: number): number | null {
  const oldCents = Math.round(oldPrice * 100);
  if (oldCents <= 0) return null;
  const diff = Math.round(newPrice * 100) - oldCents;
  // Yüzdenin 100 katı (baz puan), sıfırdan uzağa yuvarlanır.
  const bp = Math.sign(diff) * Math.floor((Math.abs(diff) * 10000 * 2 + oldCents) / (2 * oldCents));
  return bp / 100;
}

/** Satırın nedeni: "Tedarikçi zammı" / "Tedarikçi indirimi" / "Kâr oranı" / "Elle". */
export function reasonLabel(reason: string, oldPrice: number, newPrice: number): string {
  switch (reason) {
    case "supplier": {
      const tone = changeTone(oldPrice, newPrice);
      return tone === "up" ? "Tedarikçi zammı" : tone === "down" ? "Tedarikçi indirimi" : "Tedarikçi fiyatı";
    }
    case "markup":
      return "Kâr oranı";
    case "manual":
      return "Elle";
    default:
      return reason;
  }
}

/** Zaman çizelgesindeki olayın türü. */
export function eventReasonLabel(reason: string): string {
  switch (reason) {
    case "supplier":
      return "Tedarikçi fiyat listesi";
    case "markup":
      return "Kâr oranı güncellemesi";
    case "manual":
      return "Elle düzenleme";
    default:
      return reason;
  }
}

/** Özet kartlarının bağlamı: neden filtresinin açıklaması. */
export function reasonFilterLabel(reason: ReasonFilter): string {
  switch (reason) {
    case "supplier":
      return "Tedarikçi fiyatı değişiklikleri";
    case "markup":
      return "Kâr oranı değişiklikleri";
    case "manual":
      return "Elle düzenlemeler";
    default:
      return "Tüm fiyat değişiklikleri";
  }
}

/**
 * Olayın zamanı: senkron/kâr oranı olayı bir andır ("27 Eylül 2026
 * 00:05"); elle düzenlemeler gün başına gruplanır, yalnızca gün yazılır.
 */
export function eventTimeLabel(ev: Pick<PriceChangeEvent, "changed_at" | "reason">): string {
  return formatWith(ev.reason === "manual" ? istanbulDayLabelFormat : istanbulTimeLabelFormat, ev.changed_at);
}

/** Seçili olayın başlığı (URL'deki kapsamdan): "27 Eylül 2026 00:05 · Demir Profil · Tedarikçi fiyat listesi". */
export function eventScopeLabel(scope: EventScope): string {
  const when = formatWith(scope.reason === "manual" ? istanbulDayLabelFormat : istanbulTimeLabelFormat, scope.from);
  const parts = [when];
  if (scope.source) parts.push(sourceLabels(scope.source).short);
  parts.push(eventReasonLabel(scope.reason));
  return parts.join(" · ");
}

/**
 * "120 ürüne zam · 5 ürüne indirim". Senkron/kâr oranı olayında bir ürünün
 * tek satırı vardır; elle düzenleme gününde aynı ürün birkaç kez
 * düzenlenmiş olabilir, bu yüzden orada ürün değil değişiklik sayılır.
 */
export function eventCountsText(ev: Pick<PriceChangeEvent, "reason" | "change_count" | "increased" | "decreased">): string {
  const manual = ev.reason === "manual";
  const parts: string[] = [];
  if (ev.increased > 0) parts.push(manual ? `${ev.increased} fiyat artışı` : `${ev.increased} ürüne zam`);
  if (ev.decreased > 0) parts.push(manual ? `${ev.decreased} fiyat düşüşü` : `${ev.decreased} ürüne indirim`);
  if (parts.length === 0) parts.push(`${ev.change_count} değişiklik`);
  return parts.join(" · ");
}

/** Tablo başlığı yöne göre. */
export function changesTitle(direction: DirectionFilter): string {
  if (direction === "down") return "İndirim Gelen Ürünler";
  if (direction === "all") return "Fiyatı Değişen Ürünler";
  return "Zam Gelen Ürünler";
}

/**
 * Tedarikçi fiyatı sütunları gösterilsin mi? Backend bunları yalnızca
 * products.manage sahibine döndürür (diğerlerinde hep null); yetkili
 * kullanıcıda da elle düzenlemelerde kayıt yoktur -- hiçbir satırda yoksa
 * boş sütun gösterilmez.
 */
export function hasSourcePrices(rows: readonly Pick<PriceChange, "old_source_price" | "new_source_price">[]): boolean {
  return rows.some((r) => r.old_source_price !== null || r.new_source_price !== null);
}

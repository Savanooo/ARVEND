// Tedarikçi fiyat kaynağı (Ulaş) ekranının saf yardımcıları -- next/* ya da
// React içermez; hem Ürünler sayfaları hem node testleri
// (price-sources.test.mts) içe aktarabilir.
import type { PriceSource, PriceSourceCategoryMarkup, PriceSyncCounts, Product } from "./types";

export const ULAS_SOURCE = "ulas";
export const PRICE_SOURCES_PATH = "/api/v1/products/price-sources";

// backend/internal/domain/price_source.go MaxPriceSourceMarkup ile aynı.
export const MAX_MARKUP_PERCENT = 1000;

// Ayar formundaki örnek hesabın tedarikçi fiyatı.
export const EXAMPLE_SOURCE_PRICE = 500;

export type MarkupParse = { ok: true; value: number } | { ok: false; error: string };

/**
 * Kullanıcının yazdığı kâr oranını okur: "15", "12,5" (Türkçe ondalık
 * virgül), "12.5", "%15" kabul edilir. Backend 0–1000 arası, en fazla iki
 * ondalıklı değer ister. Binlik ayırıcı KABUL EDİLMEZ ("1.000" üç ondalıklı
 * sayı sayılıp reddedilir) -- 1.000 mi 1,000 mi belirsizliği olmasın.
 */
export function parseMarkupInput(raw: string): MarkupParse {
  const s = raw.trim().replace(/^%\s*/, "").replace(/\s*%$/, "");
  if (s === "") return { ok: false, error: "Kâr oranı girin." };
  if (s.startsWith("-")) return { ok: false, error: `Kâr oranı 0 ile ${MAX_MARKUP_PERCENT} arasında olmalı.` };
  const m = /^(\d+)(?:[.,](\d+))?$/.exec(s);
  if (!m) return { ok: false, error: "Geçerli bir sayı girin (ör. 15 veya 12,5)." };
  if ((m[2] ?? "").length > 2) {
    return { ok: false, error: "En fazla iki ondalık basamak girilebilir (binlik ayırıcı kullanmayın)." };
  }
  const value = Number(s.replace(",", "."));
  if (!Number.isFinite(value) || value > MAX_MARKUP_PERCENT) {
    return { ok: false, error: `Kâr oranı 0 ile ${MAX_MARKUP_PERCENT} arasında olmalı.` };
  }
  return { ok: true, value };
}

/** Oranı forma yazılacak biçimde döndürür: 15 -> "15", 12.5 -> "12,5" (binlik ayırıcısız). */
export function formatMarkupInput(value: number): string {
  return value.toLocaleString("tr-TR", { useGrouping: false, maximumFractionDigits: 2 });
}

/** Türkçe yüzde yazımı: 15 -> "%15", 12.5 -> "%12,5". */
export function formatPercent(value: number): string {
  return `%${formatMarkupInput(value)}`;
}

/**
 * Satış fiyatı = tedarikçi fiyatı × (1 + oran/100), 2 ondalığa yarım
 * yukarı yuvarlanmış -- backend domain.ApplyMarkup ile aynı sonuç. Float
 * hatası olmasın diye kuruş ve yüzde×100 tamsayılarıyla hesaplanır
 * (500 × 1,15 float'ta 574,999…'dur).
 */
export function applyMarkup(sourcePrice: number, markupPercent: number): number {
  const cents = Math.round(sourcePrice * 100);
  const basisPoints = Math.round(markupPercent * 100);
  const scaled = cents * (10000 + basisPoints);
  return Math.floor((scaled + 5000) / 10000) / 100;
}

/**
 * Ürün, kaynağın son BAŞARILI senkronunda listede görülmedi mi? Backend'in
 * missing_count hesabıyla (SummarizeSourceProducts) aynı kural: hiç
 * başarılı senkron yoksa hiçbir ürün "listede yok" sayılmaz (BYZ'den
 * aktarılmış, henüz senkronlanmamış satırların hepsi işaretlenmesin).
 */
export function isMissingFromSource(
  product: Pick<Product, "source" | "source_synced_at">,
  priceSource: Pick<PriceSource, "source" | "last_synced_at"> | null | undefined
): boolean {
  if (!priceSource?.last_synced_at || product.source !== priceSource.source) return false;
  if (!product.source_synced_at) return true;
  return Date.parse(product.source_synced_at) < Date.parse(priceSource.last_synced_at);
}

// Gece senkronu backend'de Europe/Istanbul'a göre planlanır; tarih de aynı
// saat diliminde gösterilir. Sabit saat dilimi ayrıca sunucu (SSR) ile
// tarayıcının aynı metni üretmesini sağlar -- hydration uyuşmazlığı olmaz.
const syncTimeFormat = new Intl.DateTimeFormat("tr-TR", {
  day: "numeric",
  month: "long",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZone: "Europe/Istanbul",
});

/** "2026-09-27T00:05:12+03:00" -> "27 Eylül 2026 00:05". */
export function formatSyncTime(iso: string): string {
  const t = Date.parse(iso);
  return Number.isNaN(t) ? iso : syncTimeFormat.format(t);
}

/** "toplam 628 · 3 yeni · 12 güncellenen · 613 değişmeyen · 0 listede artık yok" */
export function summarizeSyncCounts(c: PriceSyncCounts): string {
  return [
    `toplam ${c.total}`,
    `${c.created} yeni`,
    `${c.updated} güncellenen`,
    `${c.unchanged} değişmeyen`,
    `${c.missing} listede artık yok`,
  ].join(" · ");
}

/** Senkron (POST .../sync) hatasının kullanıcıya gösterilecek metni. */
export function priceSyncErrorMessage(status: number | null, message: string, sourceName: string): string {
  if (status === 409) return "Güncelleme zaten sürüyor. Biraz sonra tekrar deneyin.";
  if (status === 502) {
    return `${sourceName}'a ulaşılamadı; fiyat listesi alınamadı. Ürünlerde hiçbir değişiklik yapılmadı, lütfen daha sonra tekrar deneyin.`;
  }
  return message || "Bağlantı hatası";
}

/**
 * Başarısız senkrondan sonra kartın durum alanı (last_status/last_error)
 * sunucudan yenilensin mi? Backend yalnızca indirme hatasını (502) değil,
 * listeyi kataloğa uygularken çıkan hatayı da (500/400) "failed" olarak
 * kaydeder. 409'da başka bir senkron sürüyordur, bu istek hiçbir şey
 * yazmamıştır; status yoksa backend'e hiç ulaşılamamıştır (yenileme de
 * büyük ihtimalle düşer, sayfa hata ekranına döner).
 */
export function syncErrorUpdatesStatus(status: number | null): boolean {
  return status !== null && status !== 409;
}

/**
 * Metni cümle sonu işaretiyle bitirir. Backend'in hata metinleri
 * (PublicErrorMessage, "…uygulanamadı (sunucu hatası)") noktasızdır; ardına
 * gelen cümleyle birleşmesinler.
 */
export function asSentence(text: string): string {
  const t = text.trim();
  if (t === "") return t;
  return /[.!?…]$/.test(t) ? t : `${t}.`;
}

/**
 * Kâr oranı kaydından sonraki bildirim. Backend yalnızca kaynak fiyatı
 * bilinen (en az bir kez senkronlanmış) ürünleri yeniden fiyatlar; hiç
 * başarılı senkron yoksa böyle ürün de yoktur ve yeni oran ilk
 * güncellemede uygulanır.
 */
export function settingsSavedMessage(recomputed: number, lastSyncedAt: string | null, sourceName: string): string {
  if (recomputed > 0) return `Ayarlar kaydedildi · ${recomputed} ürünün fiyatı yeniden hesaplandı.`;
  if (!lastSyncedAt) {
    return `Ayarlar kaydedildi. Henüz ${sourceName} fiyatı bilinen ürün yok; yeni oranlar ilk ${sourceName} güncellemesinde uygulanır.`;
  }
  return "Ayarlar kaydedildi · fiyatı değişen ürün olmadı.";
}

// ---------- Kâr oranı ayar formu ----------

export interface CategoryMarkupRow {
  category: string;
  productCount: number;
  // Kullanıcının yazdığı oran; "" = varsayılan oran.
  markup: string;
}

/**
 * Formun kategori satırları: firmanın bu kaynaktan gelen ürünlerindeki
 * kategoriler + ürünü kalmamış ama oranı kayıtlı kategoriler (PUT tam
 * durumdur -- listede olmasalar kaydet'te SESSİZCE silinirlerdi).
 */
export function categoryMarkupRows(ps: Pick<PriceSource, "categories" | "category_markups">): CategoryMarkupRow[] {
  const overrides = new Map((ps.category_markups ?? []).map((m) => [m.category, m.markup_percent]));
  const rows: CategoryMarkupRow[] = ps.categories.map((c) => {
    const rate = overrides.get(c.category);
    return { category: c.category, productCount: c.product_count, markup: rate === undefined ? "" : formatMarkupInput(rate) };
  });
  const listed = new Set(ps.categories.map((c) => c.category));
  for (const m of ps.category_markups ?? []) {
    if (!listed.has(m.category)) rows.push({ category: m.category, productCount: 0, markup: formatMarkupInput(m.markup_percent) });
  }
  return rows.sort((a, b) => a.category.localeCompare(b.category, "tr"));
}

export interface PriceSourceSettingsBody {
  markup_percent: number;
  auto_sync: boolean;
  category_markups: PriceSourceCategoryMarkup[];
}

export type SettingsBuild =
  | { ok: true; body: PriceSourceSettingsBody }
  | { ok: false; markupError: string | null; rowErrors: Record<string, string> };

/**
 * Formu PUT gövdesine çevirir. Backend gövdeyi TAM durum sayar: üç alan da
 * her zaman gönderilir, oranı boş bırakılan kategoriler category_markups'a
 * girmez (= varsayılan oran).
 */
export function buildSettingsBody(form: { markup: string; autoSync: boolean; rows: readonly CategoryMarkupRow[] }): SettingsBuild {
  const markup = parseMarkupInput(form.markup);
  const rowErrors: Record<string, string> = {};
  const categoryMarkups: PriceSourceCategoryMarkup[] = [];
  for (const row of form.rows) {
    if (row.markup.trim() === "") continue;
    const parsed = parseMarkupInput(row.markup);
    if (parsed.ok) categoryMarkups.push({ category: row.category, markup_percent: parsed.value });
    else rowErrors[row.category] = parsed.error;
  }
  if (!markup.ok || Object.keys(rowErrors).length > 0) {
    return { ok: false, markupError: markup.ok ? null : markup.error, rowErrors };
  }
  return { ok: true, body: { markup_percent: markup.value, auto_sync: form.autoSync, category_markups: categoryMarkups } };
}

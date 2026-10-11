// Teklif formu, detayı ve paylaşımının saf yardımcıları -- next/* ya da
// React içermez; OfferForm/ShareOfferCard/kurulum formu ve node testleri
// (offers.test.mts) içe aktarır. Davranışın kaynağı mobil teklif formu
// (offer_create_screen.dart, product_suggestions.dart, offer_detail_screen.dart)
// ve mobile/API_CONTRACT.md "Offers" / "Products" (web = mobil).
import { formatMoney } from "./format.ts";
import { sourceLabels } from "./price-sources.ts";
import type { OfferStatus, Product } from "./types";

// ---------------------------------------------------------------------------
// Firma varsayılanları ve para birimi
// ---------------------------------------------------------------------------

// GET /offers/defaults (offers.create) -- yeni teklif formunun başlangıç
// değerleri (kurulumdaki "Teklif" adımı). valid_until, sunucunun İstanbul
// gününe göre hesapladığı varsayılan bitiştir (bugün + validity_days);
// firma süre tanımlamadıysa ikisi de null. IBAN/banka bilgisi hiç dönmez.
export interface OfferDefaults {
  vat_rate: number;
  currency: string;
  validity_days: number | null;
  valid_until: string | null;
  payment_terms: string;
  delivery_terms: string;
  footer: string;
}

export const OFFER_DEFAULTS_PATH = "/api/v1/offers/defaults";

/** Teklifin para birimi; alanı göndermeyen eski yanıtta TRY. */
export function offerCurrency(offer: { currency?: string | null } | null | undefined): string {
  return offer?.currency?.trim() || "TRY";
}

/** Metin içindeki ad: TRY -> "TL", diğerleri kodun kendisi ("USD"); mobil currencyLabel ile aynı. */
export function currencyLabel(currency: string): string {
  return !currency || currency === "TRY" ? "TL" : currency;
}

/** Teklif tutarı teklifin KENDİ para biriminde ("1.250,00 TL", "1.250,00 $"). */
export function formatOfferMoney(value: number, offer: { currency?: string | null } | null | undefined): string {
  return formatMoney(value, offerCurrency(offer));
}

/**
 * Varsayılanlar geldiğinde forma yazılacaklar. Kullanıcının o ana kadar
 * elle değiştirdiği alan (geç gelen yanıt) EZİLMEZ -- undefined döner.
 * Para birimi formda değiştirilemez; her zaman firma varsayılanıdır.
 */
export function offerDefaultsPatch(
  defaults: OfferDefaults,
  touched: { vatRate: boolean; validUntil: boolean }
): { currency: string; vatRate?: string; validUntil?: string } {
  return {
    currency: offerCurrency(defaults),
    ...(touched.vatRate ? {} : { vatRate: String(defaults.vat_rate) }),
    ...(touched.validUntil ? {} : { validUntil: defaults.valid_until ?? "" }),
  };
}

/**
 * Kayıtta gönderilecek valid_until. Backend üç durumu ayırır (bkz.
 * offer_handler.go parseValidUntil): null = yeni teklifte firma varsayılanı
 * (İstanbul bugün + firma süresi), düzenlemede mevcut tarih korunur; "" =
 * bilerek süresiz; "YYYY-MM-DD" = o tarih.
 *
 * Yeni teklifte kullanıcı tarih alanına DOKUNMADIYSA null gider: alan
 * varsayılan tarihle dolu görünse de hesabı sunucu yapar, varsayılanlar
 * okunamadıysa da firma süresi yine uygulanır. Eskiden web boş alanı ""
 * olarak gönderiyordu -- firma varsayılanı web'de hiç uygulanmıyor, her
 * teklif süresiz açılıyordu. Düzenlemede alan her zaman gönderilir (silmek
 * = süresiz yapmak).
 */
export function validUntilPayload(opts: { isEdit: boolean; validUntil: string; touched: boolean }): string | null {
  if (!opts.isEdit && !opts.touched) return null;
  return opts.validUntil.trim();
}

/**
 * Geçerlilik tarihi alanının altındaki açıklama. Yeni teklifte kullanıcı
 * tarihe dokunmadıysa kayıtta null gider ve süreyi sunucu uygular
 * (validUntilPayload) -- metin bunu söyler; varsayılanlar henüz gelmediyse
 * ya da okunamadıysa boş alan "süresiz" DEMEK DEĞİLDİR.
 */
export function validUntilHint(opts: {
  isEdit: boolean;
  touched: boolean;
  defaults: Pick<OfferDefaults, "validity_days"> | null;
}): string {
  const base = "Müşteri bu tarihten sonra teklifi onaylayamaz.";
  if (!opts.isEdit && !opts.touched) {
    if (!opts.defaults) return `Tarih seçmezseniz firma ayarındaki geçerlilik süresi uygulanır. ${base}`;
    if (opts.defaults.validity_days != null) {
      return `Firma ayarı: ${opts.defaults.validity_days} gün. ${base} Silerseniz teklif süresiz olur.`;
    }
  }
  return `${base} Boş bırakılırsa süresizdir.`;
}

/**
 * Formdaki para birimi notu (TL dışı): yeni teklifte firma ayarından gelir,
 * düzenlemede teklifin kendi birimidir ve değiştirilemez. TL'de not yok.
 */
export function offerCurrencyNote(currency: string, isEdit: boolean): string | null {
  if (currencyLabel(currency) === "TL") return null;
  return isEdit ? `Para birimi: ${currency} (teklifte değiştirilemez).` : `Para birimi: ${currency} (firma ayarı).`;
}

/** Kaydedilecek kalemlerden birim fiyatı 0 olanların sayısı (0 TL satır onayı). */
export function countZeroPriced(items: readonly { unit_price: number }[]): number {
  return items.filter((it) => it.unit_price === 0).length;
}

/**
 * 0 fiyatlı kalem geçerlidir (ikram/hediye) ama çoğunlukla fiyatı olmayan
 * ürün ya da metraj satırıdır -- sessizce kaydedilmesin (mobil onay metni).
 */
export function zeroPriceConfirmMessage(count: number, currency: string): string {
  return `${count} kalemin fiyatı 0 ${currencyLabel(currency)}. Yine de kaydedilsin mi?`;
}

// Kurulumdaki "Varsayılan Para Birimi" seçenekleri. Proje/teklif ekranları
// bu üçünü biçimlendirir (bkz. format.ts currencySuffix).
export const OFFER_CURRENCIES: readonly { code: string; label: string }[] = [
  { code: "TRY", label: "TRY — Türk Lirası" },
  { code: "USD", label: "USD — ABD Doları" },
  { code: "EUR", label: "EUR — Euro" },
];

/**
 * backend domain.NormalizeCurrency ile aynı: büyük harfe çevrilir, "TL" ve
 * "₺" TRY sayılır, boş TRY'dir; 3 harfli kod değilse null.
 */
export function normalizeCurrencyCode(raw: string): string | null {
  const c = raw.trim().toLocaleUpperCase("en-US");
  if (c === "" || c === "TL" || c === "₺") return "TRY";
  return /^[A-Z]{3}$/.test(c) ? c : null;
}

/**
 * Kurulum formundaki para birimi seçimi. Alan eskiden serbest metindi:
 * kayıtlı "TL"/"tl" TRY olarak seçilir; listede olmayan GEÇERLİ bir kod
 * (ör. "GBP") sessizce TRY'ye dönmesin diye ayrı bir seçenek olarak kalır;
 * geçersiz metin TRY'ye düşer.
 */
export function currencyChoice(saved: string): { value: string; options: { code: string; label: string }[] } {
  const value = normalizeCurrencyCode(saved) ?? "TRY";
  const known = OFFER_CURRENCIES.some((c) => c.code === value);
  return {
    value,
    options: known ? [...OFFER_CURRENCIES] : [...OFFER_CURRENCIES, { code: value, label: `${value} (kayıtlı)` }],
  };
}

// ---------------------------------------------------------------------------
// Kalemde katalogdan ürün seçme (mobil 1.5.11, product_suggestions.dart)
// ---------------------------------------------------------------------------

/** Öneri araması bu kadar karakterden sonra başlar: tek harf tüm kataloğu eşleştirir. */
export const PRODUCT_SUGGEST_MIN_CHARS = 2;
/** Yazma duraklayınca bu kadar beklenir; her tuşa bir istek gitmez. */
export const PRODUCT_SUGGEST_DEBOUNCE_MS = 300;
export const PRODUCT_SUGGEST_LIMIT = 6;

/**
 * Öneri isteği. GET /products?q= kelime bazlıdır (her kelime adda,
 * kategoride ya da tedarikçide geçmeli; "kutu 40", "demir", "40x40"
 * bulunur, ad eşleşmesi önce gelir) -- tarayıcının datalist süzmesi tek alt
 * dize ve yalnızca addı.
 */
export function productSuggestPath(query: string): string {
  const params = new URLSearchParams({ q: query.trim(), limit: String(PRODUCT_SUGGEST_LIMIT), page: "1" });
  return `/api/v1/products?${params.toString()}`;
}

/**
 * Aranacak metin; aranmayacaksa null: çok kısa ya da alan az önce seçilen
 * ürünün adını taşıyor (seçimden hemen sonra aynı ürün tekrar önerilmesin).
 */
export function productSuggestQuery(value: string, pickedName: string | null): string | null {
  const q = value.trim();
  if (q.length < PRODUCT_SUGGEST_MIN_CHARS) return null;
  if (pickedName !== null && q === pickedName.trim()) return null;
  return q;
}

/** Öneri satırının alt satırı: "kategori · tedarikçi" (elle eklenen üründe yalnızca kategori). */
export function productSuggestionMeta(p: Pick<Product, "category" | "source">): string {
  return [p.category, p.source ? sourceLabels(p.source).short : ""].filter(Boolean).join(" · ");
}

/** Gösterilenden fazla eşleşme varsa kısa not; yoksa null. */
export function moreProductsNote(total: number, shown: number): string | null {
  const more = total - shown;
  return more > 0 ? `+${more} ürün daha; aramayı daraltmak için yazmaya devam edin` : null;
}

/**
 * Katalog fiyatları TL'dir ve seçimde ÇEVRİLMEDEN yazılır (kur çevrimi
 * yok, web ve mobil aynı). Teklif TL değilse önerilerin üstünde uyarı.
 */
export function catalogCurrencyNote(currency: string): string | null {
  const label = currencyLabel(currency);
  if (label === "TL") return null;
  return `Katalog fiyatları TL; bu teklif ${label}. Seçince fiyat çevrilmeden yazılır, kontrol edin.`;
}

// Kalemin katalog bağı. linked_*: kalemin bağlandığı ürün ve bağlandığı
// andaki ad (katalogdan seçim, metraj satırı ya da kayıtlı kalem).
export interface CatalogLink {
  product_id: string | null;
  linked_product_id: string | null;
  linked_name: string | null;
}

/** Kayıtlı/metraj kaleminin bağı: product_id varsa o adla bağlıdır. */
export function catalogLinkOf(productId: string | null | undefined, name: string): CatalogLink {
  const id = productId || null;
  return { product_id: id, linked_product_id: id, linked_name: id ? name : null };
}

/**
 * Ad alanı değişti: katalog bağı YALNIZCA ad bağlandığı adla aynıyken
 * korunur; ad değişince product_id düşer, aynı ada dönülürse geri gelir
 * (mobil _DraftItem.setName). Eskiden eşleşme ADLA yapılıyordu
 * (p.name === name): aynı adlı iki üründen hep ilki bağlanıyordu.
 */
export function renameCatalogItem<T extends CatalogLink & { product_name: string }>(row: T, name: string): T {
  const linked = row.linked_name !== null && name.trim() === row.linked_name.trim();
  return { ...row, product_name: name, product_id: linked ? row.linked_product_id : null };
}

/**
 * Katalogdan seçildi: KİMLİKLE bağlanır; ad, birim ve birim fiyat ürününkiyle
 * dolar (mobil gibi birim de -- web formunda eskiden birim alanı yoktu,
 * kalem birimsiz kaydediliyordu). Hepsi sonra düzenlenebilir.
 */
export function pickCatalogProduct<T extends CatalogLink & { product_name: string; unit: string; unit_price: string }>(
  row: T,
  p: Pick<Product, "id" | "name" | "unit" | "unit_price">
): T {
  return {
    ...row,
    product_name: p.name,
    product_id: p.id,
    linked_product_id: p.id,
    linked_name: p.name,
    unit: p.unit,
    unit_price: String(p.unit_price),
  };
}

// ---------------------------------------------------------------------------
// Paylaşım linki (mobil 1.5.12, mark_sent)
// ---------------------------------------------------------------------------

export type ShareExpiresIn = "7d" | "30d" | "never";

/**
 * Taslak teklifin linkinde müşteri Kabul Et / Reddet göremez (yalnızca
 * "gönderildi" revizyon yanıtlanabilir) -- link oluşturmadan önce sorulur.
 * Diğer durumlarda link doğrudan oluşturulur.
 */
export function shareNeedsDraftChoice(status: OfferStatus): boolean {
  return status === "taslak";
}

/**
 * POST /offers/{id}/share-links gövdesi. mark_sent YALNIZCA true iken
 * gönderilir (backend bilinmeyen alanı reddeder; mobil de böyle):
 * offers.approve ister, taslak revizyonu linkle aynı işlemde
 * "gönderildi" yapar.
 */
export function shareLinkBody(expiresIn: ShareExpiresIn, markSent: boolean): { expires_in: ShareExpiresIn; mark_sent?: true } {
  return markSent ? { expires_in: expiresIn, mark_sent: true } : { expires_in: expiresIn };
}

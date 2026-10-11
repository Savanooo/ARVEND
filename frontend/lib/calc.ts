// Metraj Hesapla sonucunun saf yardımcıları -- MetrajHesaplaPanel ve node
// testleri (calc.test.mts) içe aktarır. Kaynak: mobil calc.dart
// (calcPriceSummary / nonPriceWarnings) ve mobile/API_CONTRACT.md
// "Calculations" > "Price fallback" (web = mobil).
import type { CalcResultItem, CalcRunResult, CalcWarning } from "./types";

type PricedItem = Pick<CalcResultItem, "price_source" | "price_warning">;

/** Satırın fiyatı üründen gelmedi mi (referans fiyat ya da hiç fiyat yok). */
export function hasPriceWarning(item: PricedItem): boolean {
  return !!item.price_warning?.trim();
}

/** Satırdaki kısa sebep, ilk harfi büyük: "Referans fiyat kullanıldı", "Fiyat yok". */
export function priceWarningLabel(item: PricedItem): string {
  const text = item.price_warning?.trim() ?? "";
  return text ? text.charAt(0).toLocaleUpperCase("tr-TR") + text.slice(1) : "";
}

/**
 * Fiyat uyarılarının özeti -- tabloda TEK not olarak gösterilir (satırlar
 * ayrıca işaretlenir; yeni firmada her satır için ayrı kutu listeyi
 * boğuyordu). Uyarı yoksa null. Metin mobilinkiyle aynı.
 */
export function calcPriceSummary(items: readonly PricedItem[]): string | null {
  const reference = items.filter((i) => i.price_source === "reference").length;
  const none = items.filter((i) => i.price_source === "none").length;
  if (reference === 0 && none === 0) return null;
  const parts = [
    reference > 0 ? `${reference} kalemde ürün fiyatı olmadığından reçetedeki referans fiyat kullanıldı` : "",
    none > 0 ? `${none} kalemin fiyatı yok (0 TL hesaplandı)` : "",
  ].filter(Boolean);
  return (
    `${parts.join("; ")}. Teklife eklemeden önce fiyatları kontrol edin; ` +
    "kalıcı çözüm için ürün fiyatlarını Ürünler ekranından girin."
  );
}

const PRICE_WARNING_CODES = new Set(["product_missing", "product_zero_price"]);

/**
 * Satırlarda zaten işaretlenen fiyat uyarıları (ürün yok / ürün 0 TL) üstteki
 * uyarı listesinden çıkarılır; diğer uyarılar (çevre eksik vb.) kalır. Satır
 * işareti göndermeyen eski sunucuda hepsi kalır.
 */
export function nonPriceWarnings(result: Pick<CalcRunResult, "items" | "warnings">): CalcWarning[] {
  const marked = new Set(result.items.filter(hasPriceWarning).map((i) => i.recipe_item_id));
  return result.warnings.filter((w) => !(PRICE_WARNING_CODES.has(w.code) && w.item_id && marked.has(w.item_id)));
}

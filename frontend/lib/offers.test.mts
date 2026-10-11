import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  catalogCurrencyNote,
  catalogLinkOf,
  countZeroPriced,
  currencyChoice,
  currencyLabel,
  formatOfferMoney,
  moreProductsNote,
  normalizeCurrencyCode,
  offerCurrency,
  offerDefaultsPatch,
  pickCatalogProduct,
  productSuggestionMeta,
  productSuggestPath,
  productSuggestQuery,
  renameCatalogItem,
  shareLinkBody,
  shareNeedsDraftChoice,
  validUntilPayload,
  zeroPriceConfirmMessage,
  type OfferDefaults,
} from "./offers.ts";

const DEFAULTS: OfferDefaults = {
  vat_rate: 10,
  currency: "USD",
  validity_days: 15,
  valid_until: "2026-10-24",
  payment_terms: "",
  delivery_terms: "",
  footer: "",
};

describe("firma varsayılanları", () => {
  it("dokunulmamış KDV ve geçerlilik varsayılanla dolar, para birimi her zaman firmanınki", () => {
    assert.deepEqual(offerDefaultsPatch(DEFAULTS, { vatRate: false, validUntil: false }), {
      currency: "USD",
      vatRate: "10",
      validUntil: "2026-10-24",
    });
  });

  it("geç gelen varsayılan kullanıcının değiştirdiği alanı ezmez", () => {
    assert.deepEqual(offerDefaultsPatch(DEFAULTS, { vatRate: true, validUntil: true }), { currency: "USD" });
  });

  it("firma süresi yoksa geçerlilik boş (süresiz), KDV 0 korunur", () => {
    const patch = offerDefaultsPatch(
      { ...DEFAULTS, vat_rate: 0, validity_days: null, valid_until: null, currency: "" },
      { vatRate: false, validUntil: false }
    );
    assert.deepEqual(patch, { currency: "TRY", vatRate: "0", validUntil: "" });
  });
});

describe("validUntilPayload", () => {
  it("yeni teklifte dokunulmamış tarih null gider: firma varsayılanını sunucu uygular", () => {
    assert.equal(validUntilPayload({ isEdit: false, validUntil: "", touched: false }), null);
    assert.equal(validUntilPayload({ isEdit: false, validUntil: "2026-10-24", touched: false }), null);
  });

  it("yeni teklifte bilerek silinen tarih \"\" (süresiz), seçilen tarih kendisi", () => {
    assert.equal(validUntilPayload({ isEdit: false, validUntil: "", touched: true }), "");
    assert.equal(validUntilPayload({ isEdit: false, validUntil: "2026-11-01", touched: true }), "2026-11-01");
  });

  it("düzenlemede alan her zaman gönderilir (\"\" = süresiz yap)", () => {
    assert.equal(validUntilPayload({ isEdit: true, validUntil: "", touched: false }), "");
    assert.equal(validUntilPayload({ isEdit: true, validUntil: "2026-12-31", touched: false }), "2026-12-31");
  });
});

describe("0 TL kalem onayı", () => {
  it("yalnızca birim fiyatı 0 olan kalemler sayılır", () => {
    assert.equal(countZeroPriced([{ unit_price: 0 }, { unit_price: 12.5 }, { unit_price: 0 }]), 2);
    assert.equal(countZeroPriced([{ unit_price: 0.01 }]), 0);
    assert.equal(countZeroPriced([]), 0);
  });

  it("mesaj teklifin para birimini söyler", () => {
    assert.equal(zeroPriceConfirmMessage(2, "TRY"), "2 kalemin fiyatı 0 TL. Yine de kaydedilsin mi?");
    assert.equal(zeroPriceConfirmMessage(1, "EUR"), "1 kalemin fiyatı 0 EUR. Yine de kaydedilsin mi?");
  });
});

describe("para birimi", () => {
  it("teklif tutarı kendi para biriminde biçimlenir; alan yoksa TL", () => {
    assert.equal(formatOfferMoney(1250, { currency: "USD" }), "1.250,00 $");
    assert.equal(formatOfferMoney(1250, { currency: "EUR" }), "1.250,00 €");
    assert.equal(formatOfferMoney(1250, { currency: "TRY" }), "1.250,00 TL");
    assert.equal(formatOfferMoney(1250, {}), "1.250,00 TL");
    assert.equal(formatOfferMoney(1250, null), "1.250,00 TL");
  });

  it("offerCurrency ve currencyLabel", () => {
    assert.equal(offerCurrency({ currency: " USD " }), "USD");
    assert.equal(offerCurrency({ currency: "" }), "TRY");
    assert.equal(currencyLabel("TRY"), "TL");
    assert.equal(currencyLabel(""), "TL");
    assert.equal(currencyLabel("USD"), "USD");
  });

  it("normalizeCurrencyCode backend NormalizeCurrency ile aynı", () => {
    assert.equal(normalizeCurrencyCode("TL"), "TRY");
    assert.equal(normalizeCurrencyCode(" tl "), "TRY");
    assert.equal(normalizeCurrencyCode("₺"), "TRY");
    assert.equal(normalizeCurrencyCode(""), "TRY");
    assert.equal(normalizeCurrencyCode("usd"), "USD");
    assert.equal(normalizeCurrencyCode("lira"), null);
    assert.equal(normalizeCurrencyCode("U$D"), null);
  });

  it("kurulum seçimi: serbest metin döneminin değerleri koda çevrilir, bilinmeyen kod korunur", () => {
    const codes = (raw: string) => currencyChoice(raw).options.map((o) => o.code);
    assert.deepEqual(currencyChoice("TL").value, "TRY");
    assert.deepEqual(codes("TL"), ["TRY", "USD", "EUR"]);
    assert.equal(currencyChoice("eur").value, "EUR");
    assert.equal(currencyChoice("GBP").value, "GBP");
    assert.deepEqual(codes("GBP"), ["TRY", "USD", "EUR", "GBP"]);
    assert.equal(currencyChoice("türk lirası").value, "TRY");
    assert.deepEqual(codes("türk lirası"), ["TRY", "USD", "EUR"]);
  });
});

describe("katalog önerileri", () => {
  it("istek: q, limit 6, ilk sayfa; Türkçe karakter ve boşluk kodlanır", () => {
    const url = new URL(productSuggestPath("  kutu 40 "), "http://x");
    assert.equal(url.pathname, "/api/v1/products");
    assert.equal(url.searchParams.get("q"), "kutu 40");
    assert.equal(url.searchParams.get("limit"), "6");
    assert.equal(url.searchParams.get("page"), "1");
    assert.equal(new URL(productSuggestPath("çelik"), "http://x").searchParams.get("q"), "çelik");
  });

  it("2+ karakterde aranır; seçilen ürünün adı yeniden aranmaz", () => {
    assert.equal(productSuggestQuery("d", null), null);
    assert.equal(productSuggestQuery("  d ", null), null);
    assert.equal(productSuggestQuery("de", null), "de");
    assert.equal(productSuggestQuery("Kutu Profil 40x40", "Kutu Profil 40x40"), null);
    assert.equal(productSuggestQuery("Kutu Profil 40x4", "Kutu Profil 40x40"), "Kutu Profil 40x4");
  });

  it("öneri alt satırı: kategori · tedarikçi; elle eklenen üründe yalnızca kategori", () => {
    assert.equal(productSuggestionMeta({ category: "Kutu Profil", source: "demirprofil" }), "Kutu Profil · Demir Profil");
    assert.equal(productSuggestionMeta({ category: "", source: "ulas" }), "Ulaş");
    assert.equal(productSuggestionMeta({ category: "Boya", source: "" }), "Boya");
    assert.equal(productSuggestionMeta({ category: "", source: "" }), "");
  });

  it("fazla eşleşme notu", () => {
    assert.equal(moreProductsNote(40, 6), "+34 ürün daha; aramayı daraltmak için yazmaya devam edin");
    assert.equal(moreProductsNote(6, 6), null);
    assert.equal(moreProductsNote(3, 3), null);
  });

  it("teklif TL değilse katalog fiyatı uyarısı", () => {
    assert.equal(catalogCurrencyNote("TRY"), null);
    assert.equal(
      catalogCurrencyNote("USD"),
      "Katalog fiyatları TL; bu teklif USD. Seçince fiyat çevrilmeden yazılır, kontrol edin."
    );
  });
});

describe("kalemin katalog bağı", () => {
  const blank = { product_name: "", unit: "", unit_price: "0", ...catalogLinkOf(null, "") };
  const product = { id: "p2", name: "Kutu Profil 40x40", unit: "boy", unit_price: 512.4 };

  it("seçim kimlikle bağlar; ad, birim ve fiyat ürününkiyle dolar", () => {
    const picked = pickCatalogProduct(blank, product);
    assert.equal(picked.product_id, "p2");
    assert.equal(picked.product_name, "Kutu Profil 40x40");
    assert.equal(picked.unit, "boy");
    assert.equal(picked.unit_price, "512.4");
  });

  it("aynı adlı iki üründen seçilen bağlanır (adla eşleşme yok)", () => {
    const twin = { ...product, id: "p9" };
    assert.equal(pickCatalogProduct(blank, twin).product_id, "p9");
  });

  it("ad değişince product_id düşer, aynı ada dönülünce geri gelir", () => {
    const picked = pickCatalogProduct(blank, product);
    const renamed = renameCatalogItem(picked, "Kutu Profil 40x40 galvaniz");
    assert.equal(renamed.product_id, null);
    assert.equal(renamed.product_name, "Kutu Profil 40x40 galvaniz");
    assert.equal(renameCatalogItem(renamed, "Kutu Profil 40x40 ").product_id, "p2");
  });

  it("serbest kalem yazarken hiç bağlanmaz", () => {
    const typed = renameCatalogItem(blank, "Kutu Profil 40x40");
    assert.equal(typed.product_id, null);
  });

  it("kayıtlı/metraj kalemi kendi adıyla bağlı başlar", () => {
    const saved = { product_name: "Alçı", unit: "kg", unit_price: "10", ...catalogLinkOf("p5", "Alçı") };
    assert.equal(renameCatalogItem(saved, "Alçı").product_id, "p5");
    assert.equal(renameCatalogItem(saved, "Alçı 25 kg").product_id, null);
    assert.deepEqual(catalogLinkOf(null, "Serbest"), { product_id: null, linked_product_id: null, linked_name: null });
  });
});

describe("paylaşım linki", () => {
  it("yalnızca taslakta sorulur", () => {
    assert.equal(shareNeedsDraftChoice("taslak"), true);
    assert.equal(shareNeedsDraftChoice("gönderildi"), false);
    assert.equal(shareNeedsDraftChoice("kabul edildi"), false);
    assert.equal(shareNeedsDraftChoice("reddedildi"), false);
  });

  it("mark_sent yalnızca true iken gönderilir", () => {
    assert.deepEqual(shareLinkBody("never", true), { expires_in: "never", mark_sent: true });
    assert.deepEqual(shareLinkBody("7d", false), { expires_in: "7d" });
    assert.equal("mark_sent" in shareLinkBody("30d", false), false);
  });
});

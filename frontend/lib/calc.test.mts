import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { calcPriceSummary, hasPriceWarning, nonPriceWarnings, priceWarningLabel } from "./calc.ts";
import type { CalcResultItem } from "./types.ts";

function item(id: string, patch: Partial<CalcResultItem> = {}): CalcResultItem {
  return {
    recipe_item_id: id,
    material_name: `Malzeme ${id}`,
    unit: "m²",
    quantity: "10",
    product_id: null,
    unit_price: "0",
    line_total: "0",
    group_name: "",
    calculation_type: "area_based",
    factor: "1",
    waste_percent: "0",
    rounding_type: "none",
    ...patch,
  };
}

describe("metraj fiyat uyarıları", () => {
  it("ürün fiyatı kullanıldıysa özet yok", () => {
    assert.equal(calcPriceSummary([item("a", { price_source: "product" })]), null);
    assert.equal(calcPriceSummary([item("a")]), null, "alanı göndermeyen eski sunucu");
  });

  it("referans ve fiyatsız satırlar tek notta özetlenir", () => {
    const items = [
      item("a", { price_source: "reference", price_warning: "referans fiyat kullanıldı" }),
      item("b", { price_source: "reference", price_warning: "referans fiyat kullanıldı" }),
      item("c", { price_source: "none", price_warning: "fiyat yok" }),
      item("d", { price_source: "product" }),
    ];
    assert.equal(
      calcPriceSummary(items),
      "2 kalemde ürün fiyatı olmadığından reçetedeki referans fiyat kullanıldı; 1 kalemin fiyatı yok (0 TL hesaplandı). " +
        "Teklife eklemeden önce fiyatları kontrol edin; kalıcı çözüm için ürün fiyatlarını Ürünler ekranından girin."
    );
    assert.match(calcPriceSummary([items[2]]) ?? "", /^1 kalemin fiyatı yok \(0 TL hesaplandı\)\. Teklife/);
  });

  it("satır etiketi ilk harfi büyük", () => {
    assert.equal(priceWarningLabel(item("a", { price_warning: "fiyat yok" })), "Fiyat yok");
    assert.equal(priceWarningLabel(item("a", { price_warning: "işçilik fiyatı yok" })), "İşçilik fiyatı yok");
    assert.equal(priceWarningLabel(item("a")), "");
    assert.equal(hasPriceWarning(item("a", { price_warning: "" })), false);
    assert.equal(hasPriceWarning(item("a", { price_warning: null })), false);
  });

  it("işaretlenen satırların ürün-fiyatı uyarıları listeden düşer, diğerleri kalır", () => {
    const result = {
      items: [item("a", { price_source: "none", price_warning: "fiyat yok" }), item("b")],
      warnings: [
        { item_id: "a", code: "product_zero_price", message: "a 0 TL" },
        { item_id: "b", code: "product_missing", message: "b ürün yok" },
        { item_id: "a", code: "perimeter_missing", message: "çevre yok" },
        { code: "unknown_calculation_type", message: "genel" },
      ],
    };
    assert.deepEqual(
      nonPriceWarnings(result).map((w) => w.message),
      ["b ürün yok", "çevre yok", "genel"]
    );
  });
});

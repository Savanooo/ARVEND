import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  applyMarkup,
  asSentence,
  buildSettingsBody,
  categoryMarkupRows,
  formatMarkupInput,
  formatPercent,
  formatSyncTime,
  isMissingFromSource,
  parseMarkupInput,
  priceSyncErrorMessage,
  settingsSavedMessage,
  summarizeSyncCounts,
  syncErrorUpdatesStatus,
} from "./price-sources.ts";

describe("parseMarkupInput", () => {
  it("Türkçe ondalık virgül, nokta, yüzde işareti ve boşluklar kabul edilir", () => {
    const cases: [string, number][] = [
      ["15", 15],
      ["12,5", 12.5],
      ["12.5", 12.5],
      [" 12,35 ", 12.35],
      ["%15", 15],
      ["15 %", 15],
      ["0", 0],
      ["1000", 1000],
      ["1000,00", 1000],
      ["15,10", 15.1],
    ];
    for (const [raw, want] of cases) {
      assert.deepEqual(parseMarkupInput(raw), { ok: true, value: want }, raw);
    }
  });

  it("geçersiz değerler Türkçe hata ile reddedilir", () => {
    for (const raw of ["", "  ", "abc", "1,2,3", "12,", ",5", "1e3", "12,345", "1.000", "1000,01", "1001", "-5", "99999999999999999999999"]) {
      const res = parseMarkupInput(raw);
      assert.equal(res.ok, false, raw);
      if (!res.ok) assert.ok(res.error.length > 0, raw);
    }
  });

  it("JSON'a giden sayı yazılan ondalığı birebir korur", () => {
    const res = parseMarkupInput("12,35");
    assert.ok(res.ok);
    if (res.ok) assert.equal(JSON.stringify({ m: res.value }), '{"m":12.35}');
  });
});

describe("formatMarkupInput / formatPercent", () => {
  it("binlik ayırıcı eklemez (forma geri yazılan değer yeniden okunabilmeli)", () => {
    assert.equal(formatMarkupInput(1000), "1000");
    assert.equal(formatMarkupInput(12.5), "12,5");
    assert.equal(formatMarkupInput(15), "15");
    for (const v of [0, 15, 12.35, 1000]) {
      assert.deepEqual(parseMarkupInput(formatMarkupInput(v)), { ok: true, value: v });
    }
  });

  it("yüzde işareti Türkçe'deki gibi önde", () => {
    assert.equal(formatPercent(15), "%15");
    assert.equal(formatPercent(12.5), "%12,5");
  });
});

describe("applyMarkup", () => {
  it("backend domain.ApplyMarkup ile aynı yarım-yukarı yuvarlama", () => {
    assert.equal(applyMarkup(500, 15), 575); // float'ta 574,999…
    assert.equal(applyMarkup(333.33, 12.5), 375); // 374,99625
    assert.equal(applyMarkup(4.5, 15), 5.18); // BYZ float ile 5,17 yazmıştı
    assert.equal(applyMarkup(100, 0), 100);
    assert.equal(applyMarkup(0.01, 1000), 0.11);
  });
});

describe("isMissingFromSource", () => {
  const ulas = { source: "ulas", last_synced_at: "2026-09-27T00:05:10+03:00" };

  it("son senkronda görülen ürün eksik değildir (aynı an)", () => {
    assert.equal(isMissingFromSource({ source: "ulas", source_synced_at: "2026-09-26T21:05:10Z" }, ulas), false);
  });

  it("daha eski senkronda görülen ya da hiç görülmeyen Ulaş ürünü eksiktir", () => {
    assert.equal(isMissingFromSource({ source: "ulas", source_synced_at: "2026-09-26T00:05:09+03:00" }, ulas), true);
    assert.equal(isMissingFromSource({ source: "ulas", source_synced_at: null }, ulas), true);
  });

  it("hiç başarılı senkron yoksa ya da ürün elle eklenmişse işaretlenmez", () => {
    assert.equal(isMissingFromSource({ source: "ulas", source_synced_at: null }, { source: "ulas", last_synced_at: null }), false);
    assert.equal(isMissingFromSource({ source: "", source_synced_at: null }, ulas), false);
    assert.equal(isMissingFromSource({ source: "ulas", source_synced_at: null }, null), false);
  });
});

describe("formatSyncTime", () => {
  it("İstanbul saatiyle Türkçe tarih", () => {
    assert.equal(formatSyncTime("2026-09-26T21:05:00Z"), "27 Eylül 2026 00:05");
    assert.equal(formatSyncTime("bozuk"), "bozuk");
  });
});

describe("summarizeSyncCounts / priceSyncErrorMessage", () => {
  it("sayılar", () => {
    assert.equal(
      summarizeSyncCounts({ total: 628, created: 3, updated: 12, unchanged: 613, missing: 1 }),
      "toplam 628 · 3 yeni · 12 güncellenen · 613 değişmeyen · 1 listede artık yok"
    );
  });

  it("409 ve 502 sabit metin, diğerleri backend mesajı", () => {
    assert.match(priceSyncErrorMessage(409, "x", "Ulaş"), /zaten sürüyor/);
    assert.match(priceSyncErrorMessage(502, "x", "Ulaş"), /^Ulaş'a ulaşılamadı/);
    assert.equal(priceSyncErrorMessage(400, "fiyat kaynağı bulunamadı", "Ulaş"), "fiyat kaynağı bulunamadı");
    assert.equal(priceSyncErrorMessage(null, "", "Ulaş"), "Bağlantı hatası");
  });

  it("backend'in 'failed' kaydettiği her hatada durum yenilenir; 409 ve ağ hatasında yenilenmez", () => {
    // 502 indirme hatası; 500/400 listeyi kataloğa uygulama hatası (applyAndRecord).
    for (const status of [502, 500, 400]) assert.equal(syncErrorUpdatesStatus(status), true, String(status));
    assert.equal(syncErrorUpdatesStatus(409), false);
    assert.equal(syncErrorUpdatesStatus(null), false);
  });
});

describe("asSentence", () => {
  it("noktasız backend hata metnine nokta ekler, var olanı çiftlemez", () => {
    assert.equal(asSentence("Ulaş sunucusuna bağlanılamadı"), "Ulaş sunucusuna bağlanılamadı.");
    assert.equal(
      asSentence("fiyat listesi kataloğa uygulanamadı (sunucu hatası)"),
      "fiyat listesi kataloğa uygulanamadı (sunucu hatası)."
    );
    assert.equal(asSentence("Zaman aşımı. "), "Zaman aşımı.");
    assert.equal(asSentence("Neden?"), "Neden?");
    assert.equal(asSentence("  "), "");
  });
});

describe("settingsSavedMessage", () => {
  it("yeniden hesaplanan sayı, hiç senkron yoksa ilk güncelleme notu", () => {
    assert.equal(
      settingsSavedMessage(12, "2026-09-27T00:05:00+03:00", "Ulaş"),
      "Ayarlar kaydedildi · 12 ürünün fiyatı yeniden hesaplandı."
    );
    assert.match(settingsSavedMessage(0, null, "Ulaş"), /Henüz Ulaş fiyatı bilinen ürün yok; .*ilk Ulaş güncellemesinde/);
    assert.equal(
      settingsSavedMessage(0, "2026-09-27T00:05:00+03:00", "Ulaş"),
      "Ayarlar kaydedildi · fiyatı değişen ürün olmadı."
    );
  });
});

describe("categoryMarkupRows", () => {
  it("kategoriler + ürünü kalmamış kayıtlı oranlar, Türkçe sıralı", () => {
    const rows = categoryMarkupRows({
      categories: [
        { category: "SIVA", product_count: 4 },
        { category: "ÇATI", product_count: 2 },
      ],
      category_markups: [
        { category: "ÇATI", markup_percent: 20 },
        { category: "ESKİ KATEGORİ", markup_percent: 12.5 },
      ],
    });
    assert.deepEqual(rows, [
      { category: "ÇATI", productCount: 2, markup: "20" },
      { category: "ESKİ KATEGORİ", productCount: 0, markup: "12,5" },
      { category: "SIVA", productCount: 4, markup: "" },
    ]);
  });

  it("oranları göremeyen (null) kullanıcıda satırlar boş oranla gelir", () => {
    assert.deepEqual(categoryMarkupRows({ categories: [{ category: "A", product_count: 1 }], category_markups: null }), [
      { category: "A", productCount: 1, markup: "" },
    ]);
  });
});

describe("buildSettingsBody", () => {
  it("boş kategori oranları gönderilmez; üç alan da her zaman var", () => {
    const res = buildSettingsBody({
      markup: "17,5",
      autoSync: true,
      rows: [
        { category: "A", productCount: 1, markup: "" },
        { category: "B", productCount: 2, markup: "25" },
        { category: "C", productCount: 3, markup: "  " },
      ],
    });
    assert.deepEqual(res, {
      ok: true,
      body: { markup_percent: 17.5, auto_sync: true, category_markups: [{ category: "B", markup_percent: 25 }] },
    });
  });

  it("kategori oranı yoksa category_markups boş liste", () => {
    const res = buildSettingsBody({ markup: "15", autoSync: false, rows: [] });
    assert.deepEqual(res, { ok: true, body: { markup_percent: 15, auto_sync: false, category_markups: [] } });
  });

  it("hatalar alan bazında döner", () => {
    const res = buildSettingsBody({
      markup: "",
      autoSync: false,
      rows: [
        { category: "A", productCount: 1, markup: "2000" },
        { category: "B", productCount: 1, markup: "10" },
      ],
    });
    assert.equal(res.ok, false);
    if (!res.ok) {
      assert.ok(res.markupError);
      assert.deepEqual(Object.keys(res.rowErrors), ["A"]);
    }
  });
});

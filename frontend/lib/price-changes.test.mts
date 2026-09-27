import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  addDays,
  applyFilterForm,
  changePercentOf,
  changesTitle,
  changeTone,
  cleanFilterText,
  clearEventHref,
  DEFAULT_ZAMLAR_PARAMS,
  eventAvgTone,
  eventCountsText,
  eventHref,
  eventScopeLabel,
  eventTimeLabel,
  filterFormFrom,
  formatChangePercent,
  formatChangeTime,
  formatDay,
  formatDayRange,
  hasSourcePrices,
  isSelectedEvent,
  istanbulDay,
  isValidDay,
  listQuery,
  parseZamlarParams,
  periodHref,
  reasonLabel,
  resolvePeriod,
  sourceHistoryHref,
  summaryQuery,
  syncEventScope,
  zamlarHref,
  type ZamlarParams,
} from "./price-changes.ts";

const params = (over: Partial<ZamlarParams> = {}): ZamlarParams => ({ ...DEFAULT_ZAMLAR_PARAMS, ...over });

describe("tarih yardımcıları", () => {
  it("istanbulDay: gün İstanbul saatine göre döner", () => {
    assert.equal(istanbulDay(new Date("2026-09-26T20:59:59Z")), "2026-09-26");
    assert.equal(istanbulDay(new Date("2026-09-26T21:00:00Z")), "2026-09-27");
  });

  it("isValidDay: taşan gün ve biçim dışı değerler reddedilir", () => {
    assert.equal(isValidDay("2026-09-27"), true);
    assert.equal(isValidDay("2028-02-29"), true);
    for (const bad of ["2026-02-30", "2026-13-01", "2026-9-27", "27.09.2026", "", "0099-01-01", "2026-09-27T00:00"]) {
      assert.equal(isValidDay(bad), false, bad);
    }
  });

  it("addDays ay/yıl sınırını geçer", () => {
    assert.equal(addDays("2026-03-01", -1), "2026-02-28");
    assert.equal(addDays("2026-01-01", -1), "2025-12-31");
    assert.equal(addDays("2026-09-27", -29), "2026-08-29");
    assert.equal(addDays("bozuk", 3), "bozuk");
  });

  it("Türkçe gün ve aralık yazımı", () => {
    assert.equal(formatDay("2026-09-21"), "21 Eylül 2026");
    assert.equal(formatDayRange("2026-08-29", "2026-09-27"), "29 Ağustos 2026 – 27 Eylül 2026");
    assert.equal(formatDayRange("2026-09-27", "2026-09-27"), "27 Eylül 2026");
  });

  it("tablo tarihi İstanbul saatiyle; mikrosaniyeli RFC3339Nano okunur", () => {
    assert.equal(formatChangeTime("2026-09-26T21:05:00.123456Z"), "27.09.2026 00:05");
    assert.equal(formatChangeTime("2026-09-27T00:05:12.5+03:00"), "27.09.2026 00:05");
    assert.equal(formatChangeTime("bozuk"), "bozuk");
  });
});

describe("resolvePeriod", () => {
  const today = "2026-09-27";

  it("hazır dönemler bugünü de içerir", () => {
    assert.deepEqual(resolvePeriod({ period: "7", from: "", to: "" }, today), {
      from: "2026-09-21",
      to: today,
      label: "Son 7 gün",
      error: null,
    });
    assert.equal(resolvePeriod({ period: "30", from: "", to: "" }, today).from, "2026-08-29");
    assert.equal(resolvePeriod({ period: "90", from: "", to: "" }, today).from, "2026-06-30");
    assert.deepEqual(resolvePeriod({ period: "yil", from: "", to: "" }, today), {
      from: "2026-01-01",
      to: today,
      label: "Bu yıl",
      error: null,
    });
  });

  it("özel aralık; bitiş boşsa bugün", () => {
    assert.deepEqual(resolvePeriod({ period: "ozel", from: "2026-09-01", to: "2026-09-10" }, today), {
      from: "2026-09-01",
      to: "2026-09-10",
      label: "Özel aralık",
      error: null,
    });
    assert.equal(resolvePeriod({ period: "ozel", from: "2026-09-01", to: "" }, today).to, today);
    // Tek gün de geçerli (backend bitiş gününü dahil sayar).
    assert.equal(resolvePeriod({ period: "ozel", from: today, to: today }, today).error, null);
  });

  it("geçersiz özel aralık son 30 güne döner ve açıklama verir", () => {
    for (const [from, to] of [
      ["", "2026-09-10"],
      ["2026-02-30", ""],
      ["2026-09-10", "2026-09-01"],
      ["2026-09-01", "bozuk"],
    ]) {
      const r = resolvePeriod({ period: "ozel", from, to }, today);
      assert.equal(r.from, "2026-08-29", `${from}..${to}`);
      assert.equal(r.to, today);
      assert.ok(r.error && r.error.length > 0, `${from}..${to}`);
    }
  });
});

describe("parseZamlarParams / zamlarHref", () => {
  it("boş URL varsayılanları verir; varsayılanlar URL'e yazılmaz", () => {
    assert.deepEqual(parseZamlarParams({}), DEFAULT_ZAMLAR_PARAMS);
    assert.equal(zamlarHref(DEFAULT_ZAMLAR_PARAMS), "/admin/urunler/zamlar");
  });

  it("bozuk değerler varsayılana döner", () => {
    const p = parseZamlarParams({
      period: "365",
      source: "Ulaş'; DROP",
      reason: "hepsi",
      direction: "yukari",
      sort: "price",
      page: "0",
    });
    assert.deepEqual(p, DEFAULT_ZAMLAR_PARAMS);
    assert.equal(parseZamlarParams({ page: "100001" }).page, 1);
    assert.equal(parseZamlarParams({ page: "2.5" }).page, 1);
    assert.equal(parseZamlarParams({ page: "100000" }).page, 100000);
  });

  it("from/to yalnızca özel aralıkta okunur; dizi parametrede ilki alınır", () => {
    assert.equal(parseZamlarParams({ from: "2026-01-01" }).from, "");
    const p = parseZamlarParams({ period: "ozel", from: ["2026-01-01", "2026-02-01"], to: "2026-03-01" });
    assert.equal(p.from, "2026-01-01");
    assert.equal(p.to, "2026-03-01");
  });

  it("gidiş-dönüş kayıpsız", () => {
    const p = params({
      period: "ozel",
      from: "2026-09-01",
      to: "2026-09-27",
      source: "demirprofil",
      reason: "all",
      direction: "down",
      category: "Paslanmaz Kutu Profil",
      q: "40×40 & çelik",
      sort: "largest_decrease",
      page: 3,
      event: { from: "2026-09-27T00:05:12.123456+03:00", to: "2026-09-27T00:05:12.123456+03:00", reason: "supplier", source: "demirprofil" },
    });
    const href = zamlarHref(p);
    const sp = Object.fromEntries(new URL(href, "http://x").searchParams);
    assert.deepEqual(parseZamlarParams(sp), p);
  });

  it("olay kapsamı: geçersiz zaman ya da neden yok sayılır; kaynaksız olay (elle) geçerli", () => {
    const at = "2026-09-27T00:05:12.123456Z";
    assert.equal(parseZamlarParams({ event_from: at, event_to: at, event_reason: "all" }).event, null);
    assert.equal(parseZamlarParams({ event_from: "dün", event_to: at, event_reason: "supplier" }).event, null);
    assert.deepEqual(parseZamlarParams({ event_from: at, event_to: at, event_reason: "manual" }).event, {
      from: at,
      to: at,
      reason: "manual",
      source: "",
    });
  });

  it("arama/kategori: NUL atılır, 100 karakterde (kod noktası) kesilir", () => {
    assert.equal(cleanFilterText("  a\u0000b  "), "ab");
    const long = "ş".repeat(150);
    assert.equal(Array.from(cleanFilterText(long)).length, 100);
    assert.equal(parseZamlarParams({ q: long }).q.length, 100);
  });

  it("çapa eklenir", () => {
    assert.equal(zamlarHref(params({ page: 2 }), "zam-gelen-urunler"), "/admin/urunler/zamlar?page=2#zam-gelen-urunler");
  });
});

describe("backend sorguları", () => {
  const range = { from: "2026-08-29", to: "2026-09-27" };

  it("liste: dönem + tüm filtreler + sayfa/limit", () => {
    const q = new URLSearchParams(
      listQuery(params({ source: "ulas", category: "SIVA", q: "alçı", sort: "largest_increase", page: 2 }), range)
    );
    assert.deepEqual(Object.fromEntries(q), {
      from: "2026-08-29",
      to: "2026-09-27",
      reason: "supplier",
      source: "ulas",
      direction: "up",
      category: "SIVA",
      q: "alçı",
      sort: "largest_increase",
      page: "2",
      limit: "50",
    });
  });

  it("liste: olay seçiliyse aralık, neden ve kaynak olayınkidir (kaynaksız olayda source yok)", () => {
    const at = "2026-09-27T00:00:00+03:00";
    const end = "2026-09-27T23:59:59.999999+03:00";
    const q = new URLSearchParams(
      listQuery(
        params({ source: "ulas", reason: "all", direction: "all", event: { from: at, to: end, reason: "manual", source: "" } }),
        range
      )
    );
    assert.equal(q.get("from"), at);
    assert.equal(q.get("to"), end);
    assert.equal(q.get("reason"), "manual");
    assert.equal(q.has("source"), false);
    assert.equal(q.get("direction"), "all");
  });

  it("özet: yalnızca dönem, neden ve kaynak", () => {
    assert.equal(
      summaryQuery(params({ source: "demirprofil", direction: "down", q: "x", category: "y" }), range),
      "from=2026-08-29&to=2026-09-27&reason=supplier&source=demirprofil"
    );
    assert.equal(summaryQuery(params({ reason: "all" }), range), "from=2026-08-29&to=2026-09-27&reason=all");
  });
});

describe("olay bağlantıları", () => {
  const ev = {
    changed_at: "2026-09-27T00:05:12.123456+03:00",
    from: "2026-09-27T00:05:12.123456+03:00",
    to: "2026-09-27T00:05:12.123456+03:00",
    source: "demirprofil",
    reason: "supplier" as const,
  };

  it("olay bağlantısı: tüm satırlar (yön tümü, arama/kategori temiz, 1. sayfa); dönem ve özet filtreleri korunur", () => {
    const p = params({ period: "90", source: "", reason: "all", direction: "up", q: "x", category: "y", page: 4, sort: "largest_increase" });
    const href = eventHref(p, ev);
    assert.ok(href.endsWith("#zam-gelen-urunler"));
    const got = parseZamlarParams(Object.fromEntries(new URL(href, "http://x").searchParams));
    assert.deepEqual(got, {
      ...p,
      direction: "all",
      q: "",
      category: "",
      page: 1,
      event: { from: ev.from, to: ev.to, reason: "supplier", source: "demirprofil" },
    });
    assert.equal(isSelectedEvent(got.event, ev), true);
    assert.equal(isSelectedEvent(got.event, { ...ev, source: "ulas" }), false);
    assert.equal(isSelectedEvent(null, ev), false);
  });

  it("kaynaksız (elle) olay", () => {
    const manual = { ...ev, source: null, reason: "manual" as const };
    const got = parseZamlarParams(Object.fromEntries(new URL(eventHref(params(), manual), "http://x").searchParams));
    assert.deepEqual(got.event, { from: ev.from, to: ev.to, reason: "manual", source: "" });
    assert.equal(isSelectedEvent(got.event, manual), true);
  });

  it("seçili olay: kapsamın içindeki aynı neden/kaynaklı olay, mikrosaniye hassasiyetiyle", () => {
    const second = { from: "2026-09-27T00:05:12+03:00", to: "2026-09-27T00:05:12.999999+03:00", reason: "supplier" as const, source: "demirprofil" };
    assert.equal(isSelectedEvent(second, ev), true);
    // Aynı an, UTC yazımıyla.
    assert.equal(isSelectedEvent(second, { ...ev, from: "2026-09-26T21:05:12.5Z", to: "2026-09-26T21:05:12.5Z" }), true);
    // Bir mikrosaniye dışarıda (sonraki saniye) / farklı neden / farklı kaynak.
    const next = "2026-09-27T00:05:13+03:00";
    assert.equal(isSelectedEvent(second, { ...ev, from: next, to: next }), false);
    assert.equal(isSelectedEvent(second, { ...ev, reason: "markup" }), false);
    assert.equal(isSelectedEvent(second, { ...ev, source: null }), false);
    // Olay mikrosaniyede kapsamdan taşıyorsa (Date.parse milisaniyede keserdi).
    const exact = { ...second, from: "2026-09-27T00:05:12.123456+03:00", to: "2026-09-27T00:05:12.123456+03:00" };
    assert.equal(isSelectedEvent(exact, { ...ev, to: "2026-09-27T00:05:12.123457+03:00" }), false);
    assert.equal(isSelectedEvent({ ...second, from: "bozuk" }, ev), false);
  });

  it("olayı kaldırmak yönü varsayılana döndürür", () => {
    const p = params({ direction: "all", page: 3, event: { from: ev.from, to: ev.to, reason: "supplier", source: "" } });
    assert.equal(clearEventHref(p), "/admin/urunler/zamlar#zam-gelen-urunler");
  });

  it("olay etiketleri", () => {
    assert.equal(eventTimeLabel(ev), "27 Eylül 2026 00:05");
    assert.equal(eventTimeLabel({ changed_at: "2026-09-26T21:00:00Z", reason: "manual" }), "27 Eylül 2026");
    assert.equal(
      eventScopeLabel({ from: ev.from, to: ev.to, reason: "supplier", source: "demirprofil" }),
      "27 Eylül 2026 00:05 · Demir Profil · Tedarikçi fiyat listesi"
    );
    assert.equal(
      eventScopeLabel({ from: "2026-09-27T00:00:00+03:00", to: "2026-09-27T23:59:59.999999+03:00", reason: "manual", source: "" }),
      "27 Eylül 2026 · Elle düzenleme"
    );
  });

  it("olay sayıları", () => {
    assert.equal(eventCountsText({ reason: "supplier", change_count: 125, increased: 120, decreased: 5 }), "120 ürüne zam · 5 ürüne indirim");
    assert.equal(eventCountsText({ reason: "markup", change_count: 3, increased: 0, decreased: 3 }), "3 ürüne indirim");
    assert.equal(eventCountsText({ reason: "manual", change_count: 2, increased: 2, decreased: 0 }), "2 fiyat artışı");
    assert.equal(eventCountsText({ reason: "supplier", change_count: 1, increased: 0, decreased: 0 }), "1 değişiklik");
  });
});

describe("fiyat kaynağı kartının Zam Geçmişi bağlantısı", () => {
  const today = "2026-09-27";
  const lc = { increased: 120, decreased: 5, avg_increase_percent: 4.2 };
  const parse = (href: string) => {
    const u = new URL(href, "http://x");
    return { hash: u.hash, params: parseZamlarParams(Object.fromEntries(u.searchParams)) };
  };

  it("syncEventScope: saniyeye kırpılmış zaman o saniyenin tamamıdır", () => {
    assert.deepEqual(syncEventScope("ulas", "2026-09-27T00:05:12+03:00"), {
      from: "2026-09-27T00:05:12+03:00",
      to: "2026-09-27T00:05:12.999999+03:00",
      reason: "supplier",
      source: "ulas",
    });
    assert.deepEqual(syncEventScope("ulas", "2026-09-26T21:05:12Z")?.to, "2026-09-26T21:05:12.999999Z");
    // Kesirli saniye gelirse birebir.
    const nano = "2026-09-27T00:05:12.123456+03:00";
    assert.deepEqual(syncEventScope("ulas", nano), { from: nano, to: nano, reason: "supplier", source: "ulas" });
    assert.equal(syncEventScope("ulas", "dün"), null);
    assert.equal(syncEventScope("ulas", "2026-13-45T99:00:00Z"), null);
  });

  it("yakın senkron: varsayılan dönem, tablo o senkronun satırları (yön tümü)", () => {
    const { hash, params: p } = parse(
      sourceHistoryHref({ source: "demirprofil", last_synced_at: "2026-09-20T00:05:12+03:00", last_changes: lc }, today)
    );
    assert.equal(hash, "#zam-gelen-urunler");
    assert.deepEqual(p, {
      ...DEFAULT_ZAMLAR_PARAMS,
      source: "demirprofil",
      direction: "all",
      event: {
        from: "2026-09-20T00:05:12+03:00",
        to: "2026-09-20T00:05:12.999999+03:00",
        reason: "supplier",
        source: "demirprofil",
      },
    });
    // Tablo sorgusu tam o saniyeyi ister; özet dönemi senkronu kapsar.
    const range = resolvePeriod(p, today);
    const q = new URLSearchParams(listQuery(p, range));
    assert.equal(q.get("from"), "2026-09-20T00:05:12+03:00");
    assert.equal(q.get("to"), "2026-09-20T00:05:12.999999+03:00");
    assert.equal(q.get("source"), "demirprofil");
    assert.ok(range.from <= "2026-09-20");
    // Zaman çizelgesindeki olay (mikrosaniyeli) seçili görünür.
    const at = "2026-09-20T00:05:12.482913+03:00";
    assert.equal(isSelectedEvent(p.event, { from: at, to: at, reason: "supplier", source: "demirprofil" }), true);
  });

  it("varsayılan dönemden eski senkron: senkron gününden bugüne özel aralık", () => {
    // 20 Ağustos, son 30 günün (29 Ağustos–27 Eylül) dışında; İstanbul günü UTC'den farklı.
    const href = sourceHistoryHref(
      { source: "ulas", last_synced_at: "2026-08-19T21:30:00Z", last_changes: { ...lc, decreased: 0 } },
      today
    );
    const { params: p } = parse(href);
    assert.equal(p.period, "ozel");
    assert.equal(p.from, "2026-08-20");
    assert.equal(p.to, "");
    assert.equal(p.source, "ulas");
    assert.equal(p.event?.from, "2026-08-19T21:30:00Z");
    const range = resolvePeriod(p, today);
    assert.deepEqual([range.from, range.to, range.error], ["2026-08-20", today, null]);
    // Dönemin ilk günü hâlâ varsayılan dönemde.
    assert.equal(
      parse(sourceHistoryHref({ source: "ulas", last_synced_at: "2026-08-29T00:05:00+03:00", last_changes: lc }, today)).params
        .period,
      "30"
    );
  });

  it("senkron fiyat değiştirmediyse olay yok; senkron yoksa kaynak filtreli varsayılan", () => {
    const none = { increased: 0, decreased: 0, avg_increase_percent: null };
    assert.equal(
      sourceHistoryHref({ source: "ulas", last_synced_at: "2026-09-20T00:05:12+03:00", last_changes: none }, today),
      "/admin/urunler/zamlar?source=ulas"
    );
    assert.equal(
      sourceHistoryHref({ source: "ulas", last_synced_at: "2026-07-01T00:05:12+03:00", last_changes: none }, today),
      "/admin/urunler/zamlar?period=ozel&from=2026-07-01&source=ulas"
    );
    assert.equal(
      sourceHistoryHref({ source: "demirprofil", last_synced_at: null, last_changes: null }, today),
      "/admin/urunler/zamlar?source=demirprofil"
    );
  });
});

describe("filtre formu ve dönem bağlantıları", () => {
  const range = { from: "2026-08-29", to: "2026-09-27" };
  const ev = { from: "2026-09-27T00:05:12.123456+03:00", to: "2026-09-27T00:05:12.123456+03:00", reason: "supplier" as const, source: "ulas" };

  it("form başlangıcı: özel aralıkta etkin aralık, diğer dönemlerde tarih yok", () => {
    assert.equal(filterFormFrom(params(), range).from, "");
    const custom = filterFormFrom(params({ period: "ozel", from: "2026-08-29", to: "" }), range);
    assert.equal(custom.from, "2026-08-29");
    assert.equal(custom.to, "2026-09-27");
  });

  it("yön/kategori/arama/sıralama olayı korur; 1. sayfaya döner; metin temizlenir", () => {
    const p = params({ direction: "all", page: 3, event: ev });
    const next = applyFilterForm(p, range, { ...filterFormFrom(p, range), direction: "down", q: "  kutu\u0000 ", sort: "largest_decrease" });
    assert.deepEqual(next, { ...p, direction: "down", q: "kutu", sort: "largest_decrease", page: 1 });
  });

  it("kaynak, neden ya da özel tarih değişirse olay kalkar", () => {
    const p = params({ direction: "all", event: ev });
    assert.equal(applyFilterForm(p, range, { ...filterFormFrom(p, range), source: "demirprofil" }).event, null);
    assert.equal(applyFilterForm(p, range, { ...filterFormFrom(p, range), reason: "all" }).event, null);
    const custom = params({ period: "ozel", from: "2026-08-29", to: "", event: ev });
    // Tarihlere dokunulmadıysa (bitiş bugünle dolmuş olsa da) olay kalır.
    assert.deepEqual(applyFilterForm(custom, range, filterFormFrom(custom, range)).event, ev);
    assert.equal(applyFilterForm(custom, range, { ...filterFormFrom(custom, range), from: "2026-09-01" }).event, null);
  });

  it("hazır dönemde formdaki tarih yok sayılır", () => {
    const next = applyFilterForm(params(), range, { ...filterFormFrom(params(), range), from: "2026-01-01", to: "2026-02-01" });
    assert.equal(next.from, "");
    assert.equal(next.to, "");
  });

  it("dönem bağlantısı: filtreler kalır, olay/sayfa sıfırlanır, özel aralık etkin aralıkla açılır", () => {
    const p = params({ source: "ulas", q: "alçı", page: 4 });
    assert.equal(periodHref(p, range, "7"), "/admin/urunler/zamlar?period=7&source=ulas&q=al%C3%A7%C4%B1");
    assert.equal(periodHref(p, range, "30"), "/admin/urunler/zamlar?source=ulas&q=al%C3%A7%C4%B1");
    assert.equal(
      periodHref(p, range, "ozel"),
      "/admin/urunler/zamlar?period=ozel&from=2026-08-29&to=2026-09-27&source=ulas&q=al%C3%A7%C4%B1"
    );
    // Olaydan çıkarken olay bağlantısının koyduğu "tümü" yönü de kalkar; elle seçilen yön kalır.
    assert.equal(periodHref(params({ direction: "all", event: ev }), range, "90"), "/admin/urunler/zamlar?period=90");
    assert.equal(periodHref(params({ direction: "down" }), range, "90"), "/admin/urunler/zamlar?period=90&direction=down");
  });
});

describe("yüzde ve etiketler", () => {
  it("formatChangePercent: ok yönü, Türkçe ondalık, tanımsızsa tire", () => {
    assert.equal(formatChangePercent(3.25), "↑ %3,25");
    assert.equal(formatChangePercent(-2.1), "↓ %2,1");
    assert.equal(formatChangePercent(10), "↑ %10");
    assert.equal(formatChangePercent(0), "%0");
    assert.equal(formatChangePercent(null), "—");
  });

  it("formatChangePercent: ok fiyatın yönünden gelir; %0'a yuvarlanan zam/indirim de oklu", () => {
    // 250,00 → 250,01 TL: backend change_percent 0.
    const tone = changeTone(250, 250.01);
    assert.equal(formatChangePercent(0, tone), "↑ <%0,01");
    assert.equal(formatChangePercent(0, "down"), "↓ <%0,01");
    assert.equal(formatChangePercent(0.004, "up"), "↑ <%0,01");
    assert.equal(formatChangePercent(0.01, "up"), "↑ %0,01");
    assert.equal(formatChangePercent(3.25, "up"), "↑ %3,25");
    assert.equal(formatChangePercent(-2.1, "down"), "↓ %2,1");
    assert.equal(formatChangePercent(0, "flat"), "%0");
    assert.equal(formatChangePercent(null, "up"), "—");
    // Ürün detayı: istemcide hesaplanan yüzde de aynı.
    assert.equal(formatChangePercent(changePercentOf(250, 250.01), tone), "↑ <%0,01");
  });

  it("eventAvgTone: ortalama %0'a yuvarlansa da tek yönlü olayda yön belli", () => {
    assert.equal(eventAvgTone({ avg_change_percent: 4.2, increased: 3, decreased: 1 }), "up");
    assert.equal(eventAvgTone({ avg_change_percent: -1, increased: 1, decreased: 3 }), "down");
    assert.equal(eventAvgTone({ avg_change_percent: 0, increased: 2, decreased: 0 }), "up");
    assert.equal(eventAvgTone({ avg_change_percent: 0, increased: 0, decreased: 2 }), "down");
    assert.equal(eventAvgTone({ avg_change_percent: 0, increased: 1, decreased: 1 }), "flat");
    assert.equal(eventAvgTone({ avg_change_percent: null, increased: 0, decreased: 0 }), "flat");
    assert.equal(formatChangePercent(0, eventAvgTone({ avg_change_percent: 0, increased: 2, decreased: 0 })), "↑ <%0,01");
  });

  it("changePercentOf: backend ile aynı yuvarlama, eski fiyat 0 ise null", () => {
    assert.equal(changePercentOf(100, 110), 10);
    assert.equal(changePercentOf(3, 4), 33.33);
    assert.equal(changePercentOf(3, 2), -33.33);
    assert.equal(changePercentOf(8, 9), 12.5);
    assert.equal(changePercentOf(0.3, 0.1), -66.67);
    assert.equal(changePercentOf(1.1, 1.2), 9.09); // float'ta 0.1/1.1
    assert.equal(changePercentOf(0, 5), null);
    assert.equal(changePercentOf(5, 5), 0);
  });

  it("changeTone", () => {
    assert.equal(changeTone(1, 2), "up");
    assert.equal(changeTone(2, 1), "down");
    assert.equal(changeTone(2, 2), "flat");
  });

  it("reasonLabel: tedarikçi satırında yöne göre", () => {
    assert.equal(reasonLabel("supplier", 100, 110), "Tedarikçi zammı");
    assert.equal(reasonLabel("supplier", 110, 100), "Tedarikçi indirimi");
    assert.equal(reasonLabel("markup", 100, 110), "Kâr oranı");
    assert.equal(reasonLabel("manual", 100, 90), "Elle");
  });

  it("changesTitle", () => {
    assert.equal(changesTitle("up"), "Zam Gelen Ürünler");
    assert.equal(changesTitle("down"), "İndirim Gelen Ürünler");
    assert.equal(changesTitle("all"), "Fiyatı Değişen Ürünler");
  });

  it("hasSourcePrices: yalnızca API döndürdüyse", () => {
    assert.equal(hasSourcePrices([]), false);
    assert.equal(hasSourcePrices([{ old_source_price: null, new_source_price: null }]), false);
    assert.equal(
      hasSourcePrices([
        { old_source_price: null, new_source_price: null },
        { old_source_price: null, new_source_price: 12 },
      ]),
      true
    );
  });
});

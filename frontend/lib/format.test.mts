import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  formatAgeDays,
  formatCompactMoney,
  formatCompactNumber,
  formatDateTR,
  formatHm,
  formatHours,
  formatLongDate,
  formatMoney,
  formatPercent,
  formatRelativeTime,
  formatShortDate,
  formatSignedCompactMoney,
  istanbulDate,
  shiftDay,
} from "./format.ts";
import { formatPercent as formatPercentFromPriceSources } from "./price-sources.ts";

describe("formatCompactMoney (ana sayfa D5)", () => {
  const cases: [number, string | undefined, string][] = [
    [850000, undefined, "850.000 TL"],
    [999999.6, undefined, "1 Mn TL"],
    [12500000, undefined, "12,5 Mn TL"],
    [12000000, undefined, "12 Mn TL"],
    [999960000, undefined, "1 Mr TL"],
    [1250000000, undefined, "1,3 Mr TL"],
    [-420000, undefined, "-420.000 TL"],
    [45000, "USD", "45.000 $"],
    [0, undefined, "0 TL"],
    [5100000, undefined, "5,1 Mn TL"],
    [-2200000, "EUR", "-2,2 Mn €"],
  ];
  for (const [value, currency, want] of cases) {
    it(`${value} ${currency ?? "TRY"} -> ${want}`, () => {
      assert.equal(formatCompactMoney(value, currency), want);
    });
  }

  it("\"B\"/\"Bin\" kısaltması hiç kullanılmaz", () => {
    for (const v of [1500, 15000, 150000, 999999]) {
      assert.doesNotMatch(formatCompactMoney(v), /\bB(in)?\b/);
    }
  });

  it("eksen etiketi para eki taşımaz", () => {
    assert.equal(formatCompactNumber(1200000), "1,2 Mn");
    assert.equal(formatCompactNumber(600000), "600.000");
    assert.equal(formatCompactNumber(0), "0");
    assert.equal(formatCompactNumber(-0.2), "0");
  });
});

describe("formatSignedCompactMoney", () => {
  it("işaret her zaman yazılır, sıfır işaretsizdir", () => {
    assert.equal(formatSignedCompactMoney(420000), "+420.000 TL");
    assert.equal(formatSignedCompactMoney(-70000), "-70.000 TL");
    assert.equal(formatSignedCompactMoney(2200000), "+2,2 Mn TL");
    assert.equal(formatSignedCompactMoney(0), "0 TL");
  });
});

describe("formatPercent", () => {
  it("Türkçe yüzde yazımı", () => {
    assert.equal(formatPercent(59.0), "%59");
    assert.equal(formatPercent(62.5), "%62,5");
    assert.equal(formatPercent(1234.5), "%1234,5");
  });

  it("price-sources aynı fonksiyonu yeniden dışa verir", () => {
    assert.equal(formatPercentFromPriceSources, formatPercent);
  });
});

describe("formatMoney / formatHours / formatAgeDays", () => {
  it("tam değerler", () => {
    assert.equal(formatMoney(950000), "950.000,00 TL");
    assert.equal(formatHours(4120.5), "4.120,5 sa");
    assert.equal(formatAgeDays(21), "21 gün");
  });
});

describe("tarihler", () => {
  it("formatLongDate", () => {
    assert.equal(formatLongDate("2026-09-28"), "28 Eylül 2026, Pazartesi");
    assert.equal(formatLongDate("2026-10-04"), "4 Ekim 2026, Pazar");
  });

  it("formatShortDate / formatDateTR", () => {
    assert.equal(formatShortDate("2026-09-30"), "30 Eyl");
    assert.equal(formatShortDate("2026-10-02"), "2 Eki");
    assert.equal(formatDateTR("2026-09-16"), "16.09.2026");
  });

  it("formatHm İstanbul saatini yazar", () => {
    assert.equal(formatHm("2026-09-28T09:41:12+03:00"), "09:41");
    assert.equal(formatHm("2026-09-28T06:41:12Z"), "09:41");
  });

  it("istanbulDate / shiftDay", () => {
    // UTC 22:30 İstanbul'da ertesi gündür (spec D20).
    assert.equal(istanbulDate(new Date("2026-09-30T21:30:00Z")), "2026-10-01");
    assert.equal(shiftDay("2026-09-30", 1), "2026-10-01");
    assert.equal(shiftDay("2026-01-01", -1), "2025-12-31");
  });
});

describe("formatRelativeTime", () => {
  const now = "2026-09-28T09:41:12+03:00";
  it("dakika / saat / dün", () => {
    assert.equal(formatRelativeTime("2026-09-28T09:40:40+03:00", now), "az önce");
    assert.equal(formatRelativeTime("2026-09-28T09:29:00+03:00", now), "12 dk önce");
    assert.equal(formatRelativeTime("2026-09-28T06:30:00+03:00", now), "3 sa önce");
    assert.equal(formatRelativeTime("2026-09-27T17:40:00+03:00", now), "dün 17:40");
    // UTC damgası da İstanbul saatine çevrilir.
    assert.equal(formatRelativeTime("2026-09-27T14:40:00Z", now), "dün 17:40");
  });

  it("aynı yıl / önceki yıl", () => {
    assert.equal(formatRelativeTime("2026-09-27T14:05:00+03:00", "2026-09-29T09:00:00+03:00"), "27.09 14:05");
    assert.equal(formatRelativeTime("2025-09-27T14:05:00+03:00", now), "27.09.2025");
  });

  it("gece yarısını geçen fark takvim gününe göre 'dün' olur", () => {
    assert.equal(formatRelativeTime("2026-09-27T22:00:00+03:00", "2026-09-28T00:30:00+03:00"), "dün 22:00");
  });

  it("gelecekteki damga (saat kayması) 'az önce'", () => {
    assert.equal(formatRelativeTime("2026-09-28T10:00:00+03:00", now), "az önce");
  });
});

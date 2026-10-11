import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  adjustmentCounts,
  adjustmentDecisionUI,
  BUDGET_ADJUSTMENTS_ANCHOR,
  canRecordChangeOrderDecision,
  changeOrderDecisionLines,
  isOrgOwner,
  parseCostTab,
  recordDecisionDialog,
} from "./approvals.ts";
import { webHrefForActionTarget } from "./dashboard.ts";
import { formatDateTimeTR } from "./format.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

describe("bütçe revizyonu kararı (mobil BudgetAdjustmentsScreen ile aynı)", () => {
  const viewer = { canApprove: true, locked: false, userId: "u1", isOwner: false };

  it("onay izni olan, başkasının bekleyen revizyonunda Onayla/Reddet görür", () => {
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "u2" }, viewer), "decide");
  });

  it("kişinin kendi revizyonunda düğme yerine not (Sahip değilse)", () => {
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "u1" }, viewer), "own");
  });

  it("Sahip kendi revizyonuna da karar verebilir (backend istisnası)", () => {
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "u1" }, { ...viewer, isOwner: true }), "decide");
  });

  it("izin yoksa, proje kapalıysa ya da karara bağlanmışsa hiçbir şey", () => {
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "u2" }, { ...viewer, canApprove: false }), "none");
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "u1" }, { ...viewer, canApprove: false }), "none");
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "u2" }, { ...viewer, locked: true }), "none");
    assert.equal(adjustmentDecisionUI({ status: "approved", created_by: "u2" }, viewer), "none");
    assert.equal(adjustmentDecisionUI({ status: "rejected", created_by: "u1" }, viewer), "none");
  });

  it("oluşturanı bilinmeyen (eski kayıt) ya da oturum kimliği yoksa kendi revizyonu sayılmaz", () => {
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: null }, viewer), "decide");
    assert.equal(adjustmentDecisionUI({ status: "draft" }, viewer), "decide");
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: null }, { ...viewer, userId: null }), "decide");
    assert.equal(adjustmentDecisionUI({ status: "draft", created_by: "" }, { ...viewer, userId: "" }), "decide");
  });

  it("sayılar: toplam ve onay bekleyen (draft)", () => {
    assert.deepEqual(
      adjustmentCounts([{ status: "draft" }, { status: "approved" }, { status: "draft" }, { status: "rejected" }]),
      { total: 4, pending: 2 }
    );
    assert.deepEqual(adjustmentCounts([]), { total: 0, pending: 0 });
  });

  it("Sahip = organizasyon rolü owner", () => {
    assert.equal(isOrgOwner({ organization_role_code: "owner" }), true);
    assert.equal(isOrgOwner({ organization_role_code: "admin" }), false);
    assert.equal(isOrgOwner({}), false);
    assert.equal(isOrgOwner(null), false);
  });
});

describe("ek iş: müşteri kararını personelin kaydetmesi", () => {
  it("yalnızca gönderilmiş ek işte, izinle ve açık projede", () => {
    const ok = { canRecord: true, locked: false };
    assert.equal(canRecordChangeOrderDecision({ status: "sent" }, ok), true);
    for (const status of ["draft", "approved", "rejected", "cancelled", "superseded"] as const) {
      assert.equal(canRecordChangeOrderDecision({ status }, ok), false, status);
    }
    assert.equal(canRecordChangeOrderDecision({ status: "sent" }, { canRecord: false, locked: false }), false);
    assert.equal(canRecordChangeOrderDecision({ status: "sent" }, { canRecord: true, locked: true }), false);
  });

  it("kimin kaydettiği ve not; müşterinin kendi kararında satır yok", () => {
    assert.deepEqual(
      changeOrderDecisionLines({
        decision_recorded_by: "u1",
        decision_recorded_by_name: "Ayşe Yılmaz",
        decision_note: "  telefonla onay  ",
      }),
      ["Müşterinin yanıtını Ayşe Yılmaz kaydetti.", "Not: telefonla onay"]
    );
    assert.deepEqual(
      changeOrderDecisionLines({ decision_recorded_by: "u1", decision_recorded_by_name: "", decision_note: "" }),
      ["Müşterinin yanıtını ekip kaydetti."]
    );
    assert.deepEqual(changeOrderDecisionLines({ decision_recorded_by: null, decision_note: "" }), []);
    // Eski yanıt şeklinde alanlar hiç gelmeyebilir.
    assert.deepEqual(changeOrderDecisionLines({}), []);
  });

  it("onay/red penceresi metinleri (mobil ile aynı)", () => {
    const a = recordDecisionDialog({ change_order_no: "EK-003" }, "approved", "+15.000,00 TL");
    assert.equal(a.title, "Müşteri Onayını Kaydet");
    assert.equal(a.confirmLabel, "Onaylandı Olarak İşaretle");
    assert.equal(a.danger, false);
    assert.match(a.message, /EK-003 müşteri tarafından onaylandı/);
    assert.match(a.message, /\+15\.000,00 TL değişir/);
    assert.equal(a.success, "EK-003 müşteri onayladı olarak işaretlendi.");

    const r = recordDecisionDialog({ change_order_no: "EK-003" }, "rejected", "+15.000,00 TL");
    assert.equal(r.title, "Müşteri Reddini Kaydet");
    assert.equal(r.confirmLabel, "Reddedildi Olarak İşaretle");
    assert.equal(r.danger, true);
    assert.match(r.message, /Proje bedeli değişmez/);
    assert.equal(r.success, "EK-003 müşteri reddetti olarak işaretlendi.");
  });
});

describe("bildirim bağlantıları (bütçe revizyonu, ek iş kararı)", () => {
  const P = "p1";
  it("bütçe revizyonu bildirimi Maliyet Kontrolü > Bütçe > Revizyonlar'ı açar", () => {
    assert.equal(
      webHrefForActionTarget(`/projeler/${P}/maliyet/revizyonlar`),
      `/projeler/${P}?tab=maliyet&alt=butce#${BUDGET_ADJUSTMENTS_ANCHOR}`
    );
  });

  it("ek iş kararı bildirimi Finans sekmesini açar (eskiden genel bakışa düşüyordu)", () => {
    assert.equal(webHrefForActionTarget(`/projeler/${P}/ek-isler/co1`), `/projeler/${P}?tab=finans`);
  });

  it("?alt= -> Maliyet Kontrolü alt sekmesi; bilinmeyen/boş Özet", () => {
    assert.equal(parseCostTab("butce"), "butce");
    assert.equal(parseCostTab("tahmin"), "tahmin");
    assert.equal(parseCostTab("revizyonlar"), "ozet");
    assert.equal(parseCostTab(""), "ozet");
    assert.equal(parseCostTab(null), "ozet");
    assert.equal(parseCostTab(undefined), "ozet");
  });
});

describe("formatDateTimeTR (İstanbul saati)", () => {
  it("UTC zaman damgasını İstanbul tarih + saatine çevirir", () => {
    assert.equal(formatDateTimeTR("2026-10-07T11:05:00Z"), "07.10.2026 14:05");
    // Gece yarısını geçen an ertesi güne düşer.
    assert.equal(formatDateTimeTR("2026-10-07T22:30:00Z"), "08.10.2026 01:30");
  });

  it("boş ya da okunamayan değer boş metin", () => {
    assert.equal(formatDateTimeTR(null), "");
    assert.equal(formatDateTimeTR(undefined), "");
    assert.equal(formatDateTimeTR(""), "");
    assert.equal(formatDateTimeTR("dün"), "");
  });
});

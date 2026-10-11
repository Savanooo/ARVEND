import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  approvedChangeNetByGroup,
  buildChangeItems,
  buildClaimItems,
  buildSovItems,
  canVoidPayment,
  capGroupKey,
  changeOrderActions,
  claimActions,
  claimCapCheck,
  claimEntryAmounts,
  claimPreview,
  claimUnpaidRemainder,
  emptyChangeItemDraft,
  emptySovDraft,
  latestCertifiedCumulative,
  paidAgainstClaim,
  payableClaims,
  projectIsLocked,
  round2,
  signedChangeOrderAmount,
  sovDraftAmount,
  sovDraftFromItem,
  statusMetaFor,
  subcontractActions,
  subcontractHref,
  subcontractPermsFrom,
  subcontractsTabHref,
  SUBCONTRACT_STATUS,
  type SubcontractPayment,
  type SubcontractPerms,
} from "./subcontracts.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

const ALL: SubcontractPerms = subcontractPermsFrom([
  "projects.subcontracts.read",
  "projects.subcontracts.manage",
  "projects.subcontracts.approve",
  "projects.subcontract_claims.read",
  "projects.subcontract_claims.manage",
  "projects.subcontract_claims.certify",
  "projects.subcontract_payments.read",
  "projects.subcontract_payments.manage",
]);
// Proje Yöneticisi (docs/subcontracts.md §12): manage var, approve/certify yok.
const PM: SubcontractPerms = subcontractPermsFrom([
  "projects.subcontracts.read",
  "projects.subcontracts.manage",
  "projects.subcontract_claims.read",
  "projects.subcontract_claims.manage",
]);
const NONE = subcontractPermsFrom(undefined);

describe("izinler", () => {
  it("her adımın kendi izni okunur; izin kümesi yoksa hiçbiri", () => {
    assert.equal(PM.canManage, true);
    assert.equal(PM.canApprove, false);
    assert.equal(PM.canCertifyClaims, false);
    assert.equal(PM.canReadPayments, false);
    assert.deepEqual(Object.values(NONE), Object.values(NONE).map(() => false));
  });

  it("kapalı proje: tamamlanmış ve iptal edilmiş", () => {
    assert.equal(projectIsLocked("completed"), true);
    assert.equal(projectIsLocked("cancelled"), true);
    assert.equal(projectIsLocked("active"), false);
    assert.equal(projectIsLocked("paused"), false);
  });
});

describe("sözleşme durum -> eylem", () => {
  it("taslak: düzenle (manage), aktifleştir/iptal (approve)", () => {
    const a = subcontractActions("draft", ALL, false);
    assert.equal(a.edit, true);
    assert.equal(a.activate, true);
    assert.equal(a.cancel, true);
    assert.equal(a.complete, false);
    assert.equal(a.terminate, false);
    assert.equal(a.addClaim, false);
    assert.equal(a.addChangeOrder, false);
    assert.equal(a.addPayment, false); // taslağa ödeme yok (ErrSubcontractNotPayable)
  });

  it("proje yöneticisi taslağı düzenler ama aktifleştiremez", () => {
    const a = subcontractActions("draft", PM, false);
    assert.equal(a.edit, true);
    assert.equal(a.activate, false);
    assert.equal(a.cancel, false);
  });

  it("aktif: tamamla/feshet + değişiklik emri + hakediş + ödeme", () => {
    const a = subcontractActions("active", ALL, false);
    assert.deepEqual(a, {
      edit: false,
      activate: false,
      cancel: false,
      complete: true,
      terminate: true,
      addChangeOrder: true,
      addClaim: true,
      addPayment: true,
    });
  });

  it("tamamlanmış/feshedilmiş: yalnızca ödeme", () => {
    for (const s of ["completed", "terminated"]) {
      const a = subcontractActions(s, ALL, false);
      assert.equal(a.addPayment, true, s);
      assert.equal(a.addClaim, false, s);
      assert.equal(a.addChangeOrder, false, s);
      assert.equal(a.complete || a.terminate || a.edit, false, s);
    }
    assert.equal(subcontractActions("cancelled", ALL, false).addPayment, false);
  });

  it("kapalı projede hiçbir yazma eylemi yok", () => {
    for (const s of ["draft", "active", "completed"]) {
      assert.ok(Object.values(subcontractActions(s, ALL, true)).every((v) => v === false), s);
    }
  });

  it("ödeme izni sözleşme izninden ayrı", () => {
    assert.equal(subcontractActions("active", PM, false).addPayment, false);
  });
});

describe("değişiklik emri durum -> eylem", () => {
  it("taslak: düzenle/gönder/iptal (manage)", () => {
    assert.deepEqual(changeOrderActions("draft", "active", PM, false), {
      edit: true,
      submit: true,
      cancel: true,
      approve: false,
      reject: false,
    });
  });

  it("gönderilmiş: onay/red approve ister; iptal manage", () => {
    assert.deepEqual(changeOrderActions("submitted", "active", ALL, false), {
      edit: false,
      submit: false,
      cancel: true,
      approve: true,
      reject: true,
    });
    const pm = changeOrderActions("submitted", "active", PM, false);
    assert.equal(pm.approve || pm.reject, false);
  });

  it("aktif olmayan sözleşmede onay gizli, red açık", () => {
    const a = changeOrderActions("submitted", "terminated", ALL, false);
    assert.equal(a.approve, false);
    assert.equal(a.reject, true);
  });

  it("sonuçlanmış emir ve kapalı proje: eylem yok", () => {
    for (const s of ["approved", "rejected", "cancelled"]) {
      assert.ok(Object.values(changeOrderActions(s, "active", ALL, false)).every((v) => !v), s);
    }
    assert.ok(Object.values(changeOrderActions("draft", "active", ALL, true)).every((v) => !v));
  });
});

describe("hakediş durum -> eylem", () => {
  it("taslak: düzenle/gönder/iptal (claims.manage)", () => {
    const a = claimActions("draft", "active", PM, false);
    assert.equal(a.edit && a.submit && a.cancel, true);
    assert.equal(a.approve || a.reject, false);
  });

  it("gönderilmiş: sertifika ve red certify ister (red bile)", () => {
    const a = claimActions("submitted", "active", ALL, false);
    assert.equal(a.approve, true);
    assert.equal(a.reject, true);
    assert.equal(a.cancel, true);
    const pm = claimActions("submitted", "active", PM, false);
    assert.equal(pm.approve || pm.reject, false);
    assert.equal(pm.cancel, true);
  });

  it("sertifika tamamlanmış sözleşmede açık, feshedilmişte kapalı", () => {
    assert.equal(claimActions("submitted", "completed", ALL, false).approve, true);
    assert.equal(claimActions("submitted", "terminated", ALL, false).approve, false);
    assert.equal(claimActions("submitted", "terminated", ALL, false).reject, true);
  });

  it("sertifikalı hakediş değiştirilemez", () => {
    assert.ok(Object.values(claimActions("certified", "active", ALL, false)).every((v) => !v));
  });
});

describe("ödeme iptali", () => {
  it("iptal edilmemiş + payments.manage + açık proje", () => {
    assert.equal(canVoidPayment({ voided_at: null }, ALL, false), true);
    assert.equal(canVoidPayment({ voided_at: "2026-10-01T10:00:00Z" }, ALL, false), false);
    assert.equal(canVoidPayment({ voided_at: null }, PM, false), false);
    assert.equal(canVoidPayment({ voided_at: null }, ALL, true), false);
  });

  it("ödeme yalnızca sertifikalı hakedişe bağlanır", () => {
    const claims = ["draft", "submitted", "certified", "rejected", "cancelled", "certified"].map((status, i) => ({
      id: `h${i}`,
      status,
    }));
    assert.deepEqual(
      payableClaims(claims).map((c) => c.id),
      ["h2", "h5"]
    );
  });
});

describe("bağlantılar", () => {
  it("sözleşme detayı mobil yolla aynı, odak sorgu parametresiyle", () => {
    assert.equal(subcontractHref("p1", "s1"), "/projeler/p1/taseronlar/s1");
    assert.equal(subcontractHref("p1", "s1", { claimId: "h1" }), "/projeler/p1/taseronlar/s1?hakedis=h1");
    assert.equal(subcontractHref("p1", "s1", { changeOrderId: "d1" }), "/projeler/p1/taseronlar/s1?degisiklik=d1");
    assert.equal(subcontractsTabHref("p1"), "/projeler/p1?tab=taseron");
  });
});

describe("tutar yardımcıları", () => {
  it("round2 kuruşa yuvarlar", () => {
    assert.equal(round2(1.005), 1.01);
    assert.equal(round2(0.1 + 0.2), 0.3);
    assert.equal(round2(-2.345), -2.35);
  });

  it("değişiklik emri işareti", () => {
    assert.equal(signedChangeOrderAmount({ amount: 500, change_type: "addition" }), 500);
    assert.equal(signedChangeOrderAmount({ amount: 500, change_type: "deduction" }), -500);
  });

  const pay = (amount: number, claim: string | null, voided = false): SubcontractPayment => ({
    id: `${amount}-${claim}`,
    subcontract_id: "s1",
    progress_claim_id: claim,
    amount,
    currency: "TRY",
    paid_date: "2026-10-01",
    payment_method: "",
    reference_no: "",
    description: "",
    voided_at: voided ? "2026-10-02T10:00:00Z" : null,
    void_reason: "",
    created_at: "2026-10-01T10:00:00Z",
  });

  it("hakedişe karşı ödenen ve ödenmemiş kalan: iptal ve başka hakediş sayılmaz", () => {
    const payments = [pay(30000, "h1"), pay(20000, "h1", true), pay(5000, "h2"), pay(1000, null)];
    assert.equal(paidAgainstClaim(payments, "h1"), 30000);
    assert.equal(claimUnpaidRemainder({ id: "h1", net_payable: 82500 }, payments), 52500);
    // Fazla ödeme kırpılmaz.
    assert.equal(claimUnpaidRemainder({ id: "h2", net_payable: 4000 }, payments), -1000);
  });
});

describe("SOV taslakları", () => {
  it("miktar × birim fiyat doluysa tutar ondan, yoksa girilenden (Türkçe yazım)", () => {
    assert.equal(sovDraftAmount({ ...emptySovDraft(), quantity: "12,5", unit_price: "1.000", amount: "1" }), 12500);
    assert.equal(sovDraftAmount({ ...emptySovDraft(), amount: "1.250,50" }), 1250.5);
    assert.ok(Number.isNaN(sovDraftAmount({ ...emptySovDraft(), amount: "abc" })));
  });

  it("boş satır atlanır, yarım satır hata verir", () => {
    const ok = { ...emptySovDraft(), cost_code_id: "cc1", description: " Sıva ", amount: "5.000" };
    const r = buildSovItems([ok, emptySovDraft(), { ...emptySovDraft(), description: "Boya" }, { ...ok, amount: "0" }]);
    assert.equal(r.items.length, 1);
    assert.deepEqual(r.items[0], {
      wbs_node_id: "",
      cost_code_id: "cc1",
      budget_line_id: "",
      description: "Sıva",
      quantity: null,
      unit: "",
      unit_price: null,
      original_amount: 5000,
    });
    assert.deepEqual(r.errors, { 2: "Maliyet kodu seçin.", 3: "Tutar 0'dan büyük olmalı." });
  });

  it("düzenlemede mevcut kalemin WBS/bütçe kalemi/miktarı korunur", () => {
    const d = sovDraftFromItem({
      id: "i1",
      wbs_node_id: "w1",
      cost_code_id: "cc1",
      budget_line_id: "b1",
      description: "Elektrik",
      quantity: 10,
      unit: "m2",
      unit_price: 150,
      original_amount: 1500,
      sort_order: 0,
    });
    const r = buildSovItems([d]);
    assert.deepEqual(r.items[0], {
      wbs_node_id: "w1",
      cost_code_id: "cc1",
      budget_line_id: "b1",
      description: "Elektrik",
      quantity: 10,
      unit: "m2",
      unit_price: 150,
      original_amount: 1500,
    });
  });

  it("değişiklik emri kalemleri", () => {
    const r = buildChangeItems([
      { ...emptyChangeItemDraft(), cost_code_id: "cc1", description: "Ek duvar", amount: "50.000" },
      emptyChangeItemDraft(),
      { ...emptyChangeItemDraft(), cost_code_id: "cc1", amount: "10" },
    ]);
    assert.equal(r.items.length, 1);
    assert.equal(r.items[0].amount, 50000);
    assert.deepEqual(r.errors, { 2: "Açıklama gerekli." });
  });
});

describe("hakediş kalemleri ve önizleme", () => {
  it("boş satır hakedişe girmez, 0 girer, negatif/geçersiz hata", () => {
    const r = buildClaimItems(["a", "b", "c", "d"], { a: "10.000", b: "", c: "0", d: "-5" });
    assert.deepEqual(r.items, [
      { subcontract_item_id: "a", current_progress_amount: 10000 },
      { subcontract_item_id: "c", current_progress_amount: 0 },
    ]);
    assert.deepEqual(r.errors, { d: "Negatif olamaz." });
    assert.deepEqual(claimEntryAmounts({ a: "1.000", b: "", c: "x", d: "-1" }), { a: 1000 });
  });

  it("net hakediş formülü (docs/subcontracts.md §7.3 örneği)", () => {
    assert.deepEqual(
      claimPreview({ amounts: [60000, 40000], retentionPercent: 5, advanceRecovery: 10000, otherDeductions: 2500 }),
      { gross: 100000, retention: 5000, advance: 10000, other: 2500, net: 82500 }
    );
    assert.equal(claimPreview({ amounts: [333.33], retentionPercent: 2.5, advanceRecovery: 0, otherDeductions: 0 }).retention, 8.33);
  });
});

describe("hakediş sınırları (subcontract_claim_caps.go önizlemesi)", () => {
  const sov = [
    { id: "i1", cost_code_id: "cc1", budget_line_id: null, original_amount: 300000 },
    { id: "i2", cost_code_id: "cc1", budget_line_id: null, original_amount: 200000 },
    { id: "i3", cost_code_id: "cc2", budget_line_id: "b1", original_amount: 100000 },
  ];

  it("onaylı değişikliklerin grup net etkisi; onaylı olmayan sayılmaz", () => {
    const net = approvedChangeNetByGroup([
      { status: "approved", change_type: "addition", items: [{ cost_code_id: "cc1", budget_line_id: null, amount: 50000 }] },
      { status: "approved", change_type: "deduction", items: [{ cost_code_id: "cc2", budget_line_id: "b1", amount: 20000 }] },
      { status: "submitted", change_type: "addition", items: [{ cost_code_id: "cc1", budget_line_id: null, amount: 99999 }] },
    ]);
    assert.deepEqual(net, { [capGroupKey("cc1")]: 50000, [capGroupKey("cc2", "b1")]: -20000 });
  });

  it("önceki = en son sertifikalı kümülatif; taslak/reddedilen ve düzenlenen hakediş hariç", () => {
    const prev = latestCertifiedCumulative(
      [
        { id: "h1", status: "certified", items: [{ subcontract_item_id: "i1", cumulative_progress_amount: 100000 }] },
        {
          id: "h2",
          status: "certified",
          items: [
            { subcontract_item_id: "i1", cumulative_progress_amount: 150000 },
            { subcontract_item_id: "i2", cumulative_progress_amount: 20000 },
          ],
        },
        { id: "h3", status: "rejected", items: [{ subcontract_item_id: "i1", cumulative_progress_amount: 290000 }] },
        { id: "h4", status: "certified", items: [{ subcontract_item_id: "i3", cumulative_progress_amount: 5000 }] },
      ],
      "h4"
    );
    assert.deepEqual(prev, { i1: 150000, i2: 20000 });
  });

  it("onaylı ek iş kalem sınırını yükseltir; aşım kalem uyarısı verir", () => {
    const changeNetByGroup = { [capGroupKey("cc1")]: 50000 };
    const ok = claimCapCheck({ sovItems: sov, changeNetByGroup, certified: { i1: 150000 }, currentValue: 650000, entries: { i1: 200000 } });
    assert.equal(ok.rows.i1.cap, 350000);
    assert.equal(ok.rows.i1.previous, 150000);
    assert.equal(ok.rows.i1.cumulative, 350000);
    assert.equal(ok.rows.i1.remaining, 0);
    assert.equal(ok.rows.i1.over, false);
    assert.deepEqual(ok.issues, []);

    const over = claimCapCheck({ sovItems: sov, changeNetByGroup, certified: { i1: 150000 }, currentValue: 650000, entries: { i1: 200000.01 } });
    assert.equal(over.rows.i1.over, true);
    assert.deepEqual(over.issues[0], { kind: "item", key: "i1", limit: 350000, cumulative: 350000.01 });
  });

  it("grup sınırı: ek iş grubun tamamına bir kez eklenir", () => {
    // i1 ve i2 aynı grupta: grup sınırı 500.000 + 50.000.
    const r = claimCapCheck({
      sovItems: sov,
      changeNetByGroup: { [capGroupKey("cc1")]: 50000 },
      certified: {},
      currentValue: 650000,
      entries: { i1: 340000, i2: 240000 },
    });
    assert.equal(r.rows.i1.over, false);
    assert.equal(r.rows.i2.over, false);
    assert.deepEqual(r.issues, [{ kind: "group", key: capGroupKey("cc1"), limit: 550000, cumulative: 580000 }]);
  });

  it("eksiltme kalem sınırını düşürmez ama grup sınırını düşürür", () => {
    const r = claimCapCheck({
      sovItems: sov,
      changeNetByGroup: { [capGroupKey("cc2", "b1")]: -20000 },
      certified: {},
      currentValue: 580000,
      entries: { i3: 90000 },
    });
    assert.equal(r.rows.i3.cap, 100000);
    assert.equal(r.rows.i3.over, false);
    assert.deepEqual(r.issues, [{ kind: "group", key: capGroupKey("cc2", "b1"), limit: 80000, cumulative: 90000 }]);
  });

  it("sözleşme sınırı: sertifikalı diğer kalemler de sayılır; hakediş boşsa kontrol yok", () => {
    const r = claimCapCheck({
      sovItems: sov,
      changeNetByGroup: {},
      certified: { i1: 300000, i2: 200000 },
      currentValue: 550000,
      entries: { i3: 60000 },
    });
    assert.deepEqual(r.issues, [{ kind: "contract", key: "", limit: 550000, cumulative: 560000 }]);
    assert.deepEqual(
      claimCapCheck({ sovItems: sov, changeNetByGroup: {}, certified: { i1: 999999 }, currentValue: 1, entries: {} }).issues,
      []
    );
  });
});

describe("durum rozeti", () => {
  it("bilinmeyen durum çökertmez", () => {
    assert.deepEqual(statusMetaFor(SUBCONTRACT_STATUS, "active"), { label: "Aktif", tone: "gold" });
    assert.deepEqual(statusMetaFor(SUBCONTRACT_STATUS, "mystery"), { label: "mystery", tone: "muted" });
  });
});

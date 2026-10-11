import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  costNetDiffers,
  emptyExpenseForm,
  EXPENSE_OWN_DECISION_TEXT,
  expenseActionsFor,
  expenseActorFor,
  expenseAmountInput,
  expenseCounts,
  expenseFormFrom,
  expenseIsPending,
  expenseIsWithdrawn,
  expenseProjectLabel,
  expenseRequestBody,
  expenseVatPercent,
  expenseVatRateLabel,
  expenseVatRateOptions,
  expenseVatSplit,
  myExpenseMatches,
  myExpensesHref,
  parseExpenseAmount,
  projectLedgerOpen,
  summarizeExpenses,
  type ExpenseActor,
} from "./expenses.ts";
import type { Expense } from "./types.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

const e = (amount: number, approval_status: "pending" | "approved" | "rejected", voided_at: string | null = null) => ({
  amount,
  approval_status,
  voided_at,
});

describe("masraf onayı (backend toplamlarıyla aynı kural)", () => {
  it("yalnızca onaylı ve iptal edilmemiş masraf sayılır", () => {
    assert.equal(expenseCounts(e(10, "approved")), true);
    assert.equal(expenseCounts(e(10, "pending")), false);
    assert.equal(expenseCounts(e(10, "rejected")), false);
    assert.equal(expenseCounts(e(10, "approved", "2026-10-07T10:00:00Z")), false);
  });

  it("iptal edilen bekleyen masraf artık onay beklemez", () => {
    assert.equal(expenseIsPending(e(10, "pending")), true);
    assert.equal(expenseIsPending(e(10, "pending", "2026-10-07T10:00:00Z")), false);
  });

  it("özet: onaylı toplam ile bekleyen sayı/tutar ayrı", () => {
    const s = summarizeExpenses([
      e(1000, "approved"),
      e(0.1, "approved"),
      e(0.2, "approved"),
      e(250.5, "pending"),
      e(49.5, "pending"),
      e(700, "rejected"),
      e(300, "pending", "2026-10-07T10:00:00Z"),
      e(5000, "approved", "2026-10-07T10:00:00Z"),
    ]);
    assert.deepEqual(s, { approvedTotal: 1000.3, pendingCount: 2, pendingTotal: 300 });
  });

  it("boş liste", () => {
    assert.deepEqual(summarizeExpenses([]), { approvedTotal: 0, pendingCount: 0, pendingTotal: 0 });
  });
});

// Tam masraf satırı (GET /projects/{id}/expenses, backend 0065/0066 alanları).
function row(overrides: Partial<Expense> = {}): Expense {
  return {
    id: "e1",
    project_id: "p1",
    category: "material",
    description: "Çimento",
    amount: 1200,
    currency: "TRY",
    expense_date: "2026-10-07",
    supplier_name: "Yapı Market",
    invoice_no: "F-1",
    notes: "not",
    voided_at: null,
    void_reason: "",
    created_at: "2026-10-07T10:00:00Z",
    created_by: "u-saha",
    voided_by: null,
    change_order_id: "co1",
    cost_code_id: "cc1",
    budget_line_id: "bl1",
    approval_status: "pending",
    decided_by: null,
    decided_at: null,
    decision_note: "",
    vat_rate: 20,
    vat_amount: 200,
    net_amount: 1000,
    ...overrides,
  };
}

describe("KDV (backend 0065)", () => {
  it("seçenekler: Belirtilmedi dışında %0 / %1 / %10 / %20; standart dışı kayıtlı oran eklenir", () => {
    assert.deepEqual(expenseVatRateOptions(null), [0, 1, 10, 20]);
    assert.deepEqual(expenseVatRateOptions(10), [0, 1, 10, 20]);
    assert.deepEqual(expenseVatRateOptions(18), [0, 1, 10, 20, 18]);
  });

  it("etiketler mobil ile aynı", () => {
    assert.equal(expenseVatRateLabel(0), "KDV yok (%0)");
    assert.equal(expenseVatRateLabel(1), "%1");
    assert.equal(expenseVatRateLabel(20), "%20");
    assert.equal(expenseVatRateLabel(18.5), "%18,5");
    // Ayrıntı satırı "KDV (%0)" -- "KDV (KDV yok (%0))" değil.
    assert.equal(expenseVatPercent(0), "%0");
    assert.equal(expenseVatPercent(20), "%20");
    assert.equal(expenseVatPercent(18.5), "%18,5");
  });

  it("önizleme sunucu formülüyle: KDV = round(tutar × oran / (100 + oran), 2)", () => {
    assert.deepEqual(expenseVatSplit(1200, 20), { vat: 200, net: 1000 });
    assert.deepEqual(expenseVatSplit(100, 10), { vat: 9.09, net: 90.91 });
    assert.deepEqual(expenseVatSplit(64000, 1), { vat: 633.66, net: 63366.34 });
    assert.deepEqual(expenseVatSplit(500, 0), { vat: 0, net: 500 });
    assert.equal(expenseVatSplit(0, 20), null);
    assert.equal(expenseVatSplit(Number(""), 20), null);
    assert.equal(expenseVatSplit(Number("abc"), 20), null);
  });

  it("Maliyet (KDV hariç) yalnızca brütten farklıysa (ve alan geldiyse)", () => {
    assert.equal(costNetDiffers(1200, 1000), true);
    assert.equal(costNetDiffers(1200, 1200), false);
    assert.equal(costNetDiffers(1200, 1199.999), false);
    assert.equal(costNetDiffers(1200, undefined), false);
    assert.equal(costNetDiffers(1200, null), false);
  });
});

describe("form gövdesi (POST / PUT)", () => {
  it("vat_rate YALNIZCA oran seçilince gönderilir", () => {
    const blank = { ...emptyExpenseForm("2026-10-09"), description: " Kum ", amount: "250.5" };
    const body = expenseRequestBody(blank, { currency: "TRY", canLink: true, idempotencyKey: "k1" });
    assert.equal("vat_rate" in body, false);
    assert.equal(body.amount, 250.5);
    assert.equal(body.description, "Kum");
    assert.equal(body.idempotency_key, "k1");
    assert.equal(body.expense_date, "2026-10-09");
    const zero = expenseRequestBody({ ...blank, vat_rate: 0 }, { currency: "TRY", canLink: true });
    assert.equal(zero.vat_rate, 0);
    assert.equal("idempotency_key" in zero, false);
  });

  it("düzenleme okunan HER alanı geri gönderir (bağlar ve KDV dahil)", () => {
    const e = row();
    const body = expenseRequestBody(expenseFormFrom(e), { currency: e.currency, canLink: true });
    assert.deepEqual(body, {
      category: "material",
      description: "Çimento",
      amount: 1200,
      currency: "TRY",
      expense_date: "2026-10-07",
      supplier_name: "Yapı Market",
      invoice_no: "F-1",
      notes: "not",
      change_order_id: "co1",
      cost_code_id: "cc1",
      budget_line_id: "bl1",
      vat_rate: 20,
    });
  });

  it("KDV'si belirtilmemiş masrafın düzenlemesinde vat_rate yine gönderilmez", () => {
    const e = row({ vat_rate: null, vat_amount: null, net_amount: null, change_order_id: undefined });
    const body = expenseRequestBody(expenseFormFrom(e), { currency: "TRY", canLink: true });
    assert.equal("vat_rate" in body, false);
    assert.equal(body.change_order_id, "");
  });

  it("finance.manage yoksa üç bağ BOŞ gider (sunucu dolu bağı 403 ile reddeder)", () => {
    const body = expenseRequestBody(expenseFormFrom(row()), { currency: "TRY", canLink: false });
    assert.equal(body.change_order_id, "");
    assert.equal(body.cost_code_id, "");
    assert.equal(body.budget_line_id, "");
    assert.equal(body.vat_rate, 20);
  });

  it("tutar Türkçe yazımla okunur (mobil parseAmountInput ile aynı)", () => {
    assert.equal(parseExpenseAmount("64.000"), 64000);
    assert.equal(parseExpenseAmount("1.250,50"), 1250.5);
    assert.equal(parseExpenseAmount("1250.50"), 1250.5);
    assert.equal(parseExpenseAmount(" 750 "), 750);
    for (const bad of ["", "0", "0,00", "-5", "abc", "1,2,3"]) {
      assert.equal(parseExpenseAmount(bad), null, `"${bad}" geçersiz olmalıydı`);
    }
    const body = expenseRequestBody(
      { ...emptyExpenseForm("2026-10-09"), description: "Kum", amount: "64.000" },
      { currency: "TRY", canLink: false }
    );
    assert.equal(body.amount, 64000);
  });

  it("düzenlemede tutar Türkçe yazımla dolar ve aynen geri okunur", () => {
    assert.equal(expenseAmountInput(1250.5), "1.250,5");
    assert.equal(expenseAmountInput(64000), "64.000");
    assert.equal(expenseAmountInput(99.99), "99,99");
    for (const amount of [0.01, 99.99, 1250.5, 64000, 1234567.89]) {
      assert.equal(parseExpenseAmount(expenseAmountInput(amount)), amount);
    }
  });

  it("tarih gün kısmına indirgenir; bilinmeyen kategori aynen kalır", () => {
    const f = expenseFormFrom(row({ expense_date: "2026-10-07T00:00:00Z", category: "fuel" as Expense["category"] }));
    assert.equal(f.expense_date, "2026-10-07");
    assert.equal(f.category, "fuel");
  });
});

describe("kim ne yapabilir (backend 0066, mobil expenseActionsFor)", () => {
  const saha: ExpenseActor = { userId: "u-saha", isOwner: false, canManageFinance: false, canCreate: true, canApprove: false };
  const finans: ExpenseActor = { userId: "u-fin", isOwner: false, canManageFinance: true, canCreate: true, canApprove: false };
  const yonetici: ExpenseActor = { userId: "u-yon", isOwner: false, canManageFinance: true, canCreate: true, canApprove: true };
  const sahip: ExpenseActor = { userId: "u-sahip", isOwner: true, canManageFinance: true, canCreate: true, canApprove: true };
  const none = { canEdit: false, canVoid: false, canWithdraw: false, canDecide: false, ownDecisionBlocked: false };

  it("saha: kendi bekleyen/reddedilen masrafında Düzenle + Geri Çek; onaylıda ve başkasınınkinde hiçbiri", () => {
    assert.deepEqual(expenseActionsFor(saha, row(), true), { ...none, canEdit: true, canWithdraw: true });
    assert.deepEqual(expenseActionsFor(saha, row({ approval_status: "rejected" }), true), {
      ...none,
      canEdit: true,
      canWithdraw: true,
    });
    assert.deepEqual(expenseActionsFor(saha, row({ approval_status: "approved" }), true), none);
    assert.deepEqual(expenseActionsFor(saha, row({ created_by: "u-baska" }), true), none);
  });

  it("masraf girme izni kaldırılmışsa kendi masrafında da işlem yok", () => {
    assert.deepEqual(expenseActionsFor({ ...saha, canCreate: false }, row(), true), none);
  });

  it("finans yöneticisi: her masrafta Düzenle + İptal Et (Geri Çek değil), onay izni yoksa karar yok", () => {
    for (const status of ["pending", "approved", "rejected"] as const) {
      assert.deepEqual(expenseActionsFor(finans, row({ approval_status: status }), true), {
        ...none,
        canEdit: true,
        canVoid: true,
      });
    }
  });

  it("onaylayıcı: başkasının bekleyen masrafına karar verir; kendi masrafında not görür", () => {
    assert.equal(expenseActionsFor(yonetici, row(), true).canDecide, true);
    const own = expenseActionsFor(yonetici, row({ created_by: "u-yon" }), true);
    assert.equal(own.canDecide, false);
    assert.equal(own.ownDecisionBlocked, true);
    assert.equal(expenseActionsFor(yonetici, row({ approval_status: "approved" }), true).canDecide, false);
    assert.equal(EXPENSE_OWN_DECISION_TEXT, "Bu masrafı sen girdin; başka bir yöneticinin onaylaması gerekir.");
  });

  it("Sahip kendi masrafına da karar verir (üstünde onaylayacak kimse yok)", () => {
    const own = expenseActionsFor(sahip, row({ created_by: "u-sahip" }), true);
    assert.equal(own.canDecide, true);
    assert.equal(own.ownDecisionBlocked, false);
  });

  it("kapalı projede ya da iptal edilmiş masrafta hiçbir işlem yok", () => {
    assert.deepEqual(expenseActionsFor(sahip, row(), false), none);
    assert.deepEqual(expenseActionsFor(saha, row(), false), none);
    assert.deepEqual(expenseActionsFor(sahip, row({ voided_at: "2026-10-08T10:00:00Z" }), true), none);
  });

  it("created_by'sız (eski) masraf kimsenin 'kendi' masrafı sayılmaz", () => {
    assert.deepEqual(expenseActionsFor({ ...saha, userId: null }, row({ created_by: null }), true), none);
    assert.deepEqual(expenseActionsFor(saha, row({ created_by: null }), true), none);
  });

  it("actor oturumdan fail-closed kurulur", () => {
    assert.deepEqual(expenseActorFor(null), {
      userId: null,
      isOwner: false,
      canManageFinance: false,
      canCreate: false,
      canApprove: false,
    });
    assert.deepEqual(
      expenseActorFor({
        id: "u1",
        organization_role_code: "owner",
        permissions: ["projects.expenses.create", "projects.expenses.approve"],
      }),
      { userId: "u1", isOwner: true, canManageFinance: false, canCreate: true, canApprove: true }
    );
  });

  it("proje kilidi: tamamlanmış/iptal projede kapalı", () => {
    assert.equal(projectLedgerOpen("active"), true);
    assert.equal(projectLedgerOpen("paused"), true);
    assert.equal(projectLedgerOpen("completed"), false);
    assert.equal(projectLedgerOpen("cancelled"), false);
  });
});

describe("Masraflarım", () => {
  it("geri çekildi = iptal eden giren kişi", () => {
    assert.equal(expenseIsWithdrawn(row({ voided_at: "2026-10-08T10:00:00Z", voided_by: "u-saha" })), true);
    assert.equal(expenseIsWithdrawn(row({ voided_at: "2026-10-08T10:00:00Z", voided_by: "u-fin" })), false);
    assert.equal(expenseIsWithdrawn(row({ voided_by: "u-saha" })), false);
    assert.equal(expenseIsWithdrawn(row({ voided_at: "2026-10-08T10:00:00Z", created_by: null, voided_by: null })), false);
  });

  it("süzgeçler: Tümü iptalleri de gösterir, durum süzgeçleri yalnızca iptal edilmemişleri", () => {
    const voided = row({ approval_status: "rejected", voided_at: "2026-10-08T10:00:00Z" });
    assert.equal(myExpenseMatches("all", voided), true);
    assert.equal(myExpenseMatches("rejected", voided), false);
    assert.equal(myExpenseMatches("rejected", row({ approval_status: "rejected" })), true);
    assert.equal(myExpenseMatches("approved", row({ approval_status: "approved" })), true);
    assert.equal(myExpenseMatches("pending", row()), true);
    assert.equal(myExpenseMatches("pending", row({ voided_at: "2026-10-08T10:00:00Z" })), false);
  });

  it("bağlantı: ?proje= ve ?masraf= (mobil ile aynı parametreler)", () => {
    assert.equal(myExpensesHref(), "/masraflarim");
    assert.equal(myExpensesHref({ projectId: "p1" }), "/masraflarim?proje=p1");
    assert.equal(myExpensesHref({ expenseId: "e 1" }), "/masraflarim?masraf=e+1");
    assert.equal(myExpensesHref({ projectId: "p1", expenseId: "e1" }), "/masraflarim?proje=p1&masraf=e1");
    assert.equal(myExpensesHref({ projectId: null, expenseId: null }), "/masraflarim");
  });

  it("proje etiketi", () => {
    assert.equal(expenseProjectLabel("PRJ-2026-001", "Ataşehir Konut"), "PRJ-2026-001 · Ataşehir Konut");
    assert.equal(expenseProjectLabel("", "Ataşehir Konut"), "Ataşehir Konut");
  });
});

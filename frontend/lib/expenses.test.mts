import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { expenseCounts, expenseIsPending, summarizeExpenses } from "./expenses.ts";

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

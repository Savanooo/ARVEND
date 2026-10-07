// Masraf onayının (backend migration 0060) saf yardımcıları -- Finans
// sekmesi ve Maliyet > Gerçekleşen kullanır, node testleri (expenses.test.mts)
// içe aktarır. Kural backend toplamlarıyla aynı: yalnızca ONAYLI ve iptal
// edilmemiş masraf sayılır; bekleyen/reddedilen listede durumuyla görünür.
import type { Expense } from "./types";

type ExpenseLike = Pick<Expense, "amount" | "voided_at" | "approval_status">;

/** Masraf para toplamlarına girer mi (onaylı ve iptal edilmemiş). */
export function expenseCounts(e: ExpenseLike): boolean {
  return !e.voided_at && e.approval_status === "approved";
}

/** Onay bekleyen (iptal edilmemiş) masraf. */
export function expenseIsPending(e: ExpenseLike): boolean {
  return !e.voided_at && e.approval_status === "pending";
}

export interface ExpenseApprovalSummary {
  /** Onaylı masrafların toplamı -- finans özetindeki "masraf toplamı". */
  approvedTotal: number;
  pendingCount: number;
  pendingTotal: number;
}

export function summarizeExpenses(expenses: ExpenseLike[]): ExpenseApprovalSummary {
  const out: ExpenseApprovalSummary = { approvedTotal: 0, pendingCount: 0, pendingTotal: 0 };
  for (const e of expenses) {
    if (expenseCounts(e)) out.approvedTotal += e.amount;
    else if (expenseIsPending(e)) {
      out.pendingCount += 1;
      out.pendingTotal += e.amount;
    }
  }
  // Kuruş toplamları ikili kayan noktada sürüklenmesin (0.1 + 0.2).
  out.approvedTotal = Math.round(out.approvedTotal * 100) / 100;
  out.pendingTotal = Math.round(out.pendingTotal * 100) / 100;
  return out;
}

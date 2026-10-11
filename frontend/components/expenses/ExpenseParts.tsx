"use client";

import { Badge } from "@/components/ui/Badge";
import { Modal } from "@/components/ui/Modal";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { expenseIsWithdrawn, expenseVatRateLabel } from "@/lib/expenses";
import { formatMoney } from "@/lib/format";
import { EXPENSE_APPROVAL_STATUS } from "@/lib/status";
import type { BudgetLine, ChangeOrder, Expense, OrganizationCostCode } from "@/lib/types";

import { ExpenseForm } from "./ExpenseForm";

// Masraf tablolarının ortak parçaları (Finans > Masraflar, Masraflarım).

/** Durum rozeti: iptal edilende "Geri çekildi" (giren kişi çekti) / "İptal edildi", diğerlerinde onay durumu. */
export function ExpenseStatusBadge({ expense }: { expense: Expense }) {
  if (expense.voided_at) {
    return <Badge tone="muted">{expenseIsWithdrawn(expense) ? "Geri çekildi" : "İptal edildi"}</Badge>;
  }
  return <StatusBadge status={expense.approval_status} registry={EXPENSE_APPROVAL_STATUS} />;
}

/**
 * KDV hücresi: oran + tutarın içindeki KDV + KDV hariç tutar (sunucunun
 * hesabı); oran girilmemişse "Belirtilmedi" (tutarın tamamı maliyet sayılır).
 */
export function ExpenseVatCell({ expense }: { expense: Expense }) {
  if (expense.vat_rate == null) return <span className="text-xs text-text-muted">Belirtilmedi</span>;
  return (
    <div className="flex flex-col text-xs">
      <span className="text-text">
        {expenseVatRateLabel(expense.vat_rate)}
        {expense.vat_amount != null && ` · ${formatMoney(expense.vat_amount, expense.currency)}`}
      </span>
      {expense.net_amount != null && (
        <span className="text-text-muted">KDV hariç {formatMoney(expense.net_amount, expense.currency)}</span>
      )}
    </div>
  );
}

/** "Düzenle" penceresi: aynı form, masrafla dolu (PUT satırı bütünüyle yeniden yazar). */
export function ExpenseEditModal({
  projectId,
  expense,
  canLink,
  changeOrders,
  budgetLines,
  costCodes,
  onClose,
}: {
  projectId: string;
  expense: Expense;
  canLink: boolean;
  changeOrders?: ChangeOrder[];
  budgetLines?: BudgetLine[];
  costCodes?: OrganizationCostCode[];
  onClose: () => void;
}) {
  return (
    <Modal open onClose={onClose} title="Masrafı Düzenle" widthClassName="max-w-3xl">
      <ExpenseForm
        projectId={projectId}
        currency={expense.currency}
        initial={expense}
        canLink={canLink}
        changeOrders={changeOrders}
        budgetLines={budgetLines}
        costCodes={costCodes}
        idPrefix={`expense_edit_${expense.id}`}
        onDone={onClose}
        onCancel={onClose}
      />
    </Modal>
  );
}

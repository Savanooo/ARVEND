"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney } from "@/lib/format";
import type { Expense } from "@/lib/types";

// Masraf satırı işlemleri -- Finans > Masraflar ve Masraflarım AYNI akışı
// kullanır (mobil ledger_entry_sheet.dart ile aynı metinler):
//   Onayla (onay sorulur) / Reddet (gerekçe zorunlu)   projects.expenses.approve
//   İptal Et (gerekçeli)                      projects.finance.manage
//   Geri Çek (gerekçesiz, kendi masrafı)      projects.expenses.create
// Hepsi POST .../expenses/{id}/{approve|reject|void}. Görünürlük çağıranda
// (expenseActionsFor); sunucu yeniden denetler -- 403/409 mesajı olduğu gibi
// gösterilir ve liste tazelenir (kayıt bu arada değişmiş olabilir).
export function useExpenseMutations() {
  const router = useRouter();
  const toast = useToast();
  const { askReason, dialog: reasonDialog } = useReasonDialog();
  const { confirm, dialog: confirmDialog } = useConfirmDialog();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<unknown>, doneMessage: string): Promise<boolean> {
    setBusy(true);
    setError(null);
    try {
      await fn();
      router.refresh();
      toast.success(doneMessage);
      return true;
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      // 404/409: proje kapandı, masraf zaten karar almış/iptal edilmiş --
      // ekrandaki eski satır tazelensin.
      if (err instanceof ApiError && (err.status === 404 || err.status === 409)) router.refresh();
      return false;
    } finally {
      setBusy(false);
    }
  }

  const path = (projectId: string, e: Expense, action: string) =>
    `/api/v1/projects/${projectId}/expenses/${e.id}/${action}`;

  // Onay gerçekleşen maliyeti ve kârı değiştirir: mobil gibi önce sorulur.
  async function approve(projectId: string, e: Expense): Promise<boolean> {
    const ok = await confirm({
      title: "Masrafı Onayla",
      message: `${formatMoney(e.amount, e.currency)} tutarındaki masraf onaylanır ve gerçekleşen maliyete, kâra girer.`,
      confirmLabel: "Onayla",
    });
    if (!ok) return false;
    return run(() => apiClient(path(projectId, e, "approve"), { method: "POST" }), "Masraf onaylandı.");
  }

  async function reject(projectId: string, e: Expense): Promise<boolean> {
    const reason = await askReason({
      title: "Masrafı Reddet",
      message: `${formatMoney(e.amount, e.currency)} tutarındaki masraf reddedilecek; toplamlara girmez. Masrafı giren gerekçeyi görür; düzeltilirse yeniden onaya gelir.`,
      label: "Red nedeni",
      confirmLabel: "Reddet",
      danger: true,
      required: true,
    });
    if (reason === null) return false;
    return run(
      () => apiClient(path(projectId, e, "reject"), { method: "POST", body: JSON.stringify({ reason }) }),
      "Masraf reddedildi."
    );
  }

  async function voidExpense(projectId: string, e: Expense): Promise<boolean> {
    const reason = await askReason({
      title: "Masrafı İptal Et",
      message: `${formatMoney(e.amount, e.currency)} tutarındaki masraf iptal edilecek; kayıt silinmez, İPTAL olarak işaretlenir.`,
      label: "İptal nedeni",
      confirmLabel: "İptal Et",
      cancelLabel: "Vazgeç",
      danger: true,
    });
    if (reason === null) return false;
    return run(
      () => apiClient(path(projectId, e, "void"), { method: "POST", body: JSON.stringify({ reason }) }),
      "Masraf iptal edildi."
    );
  }

  // Giren kişinin "Geri Çek"i: gerekçe istenmez (iz sunucuda: iptal eden = giren).
  async function withdraw(projectId: string, e: Expense): Promise<boolean> {
    const ok = await confirm({
      title: "Masrafı Geri Çek",
      message: 'Masraf onaydan çekilir ve iptal edilir. Kayıt silinmez; Masraflarım\'da "Geri çekildi" olarak kalır.',
      confirmLabel: "Geri Çek",
      danger: true,
    });
    if (!ok) return false;
    return run(
      () => apiClient(path(projectId, e, "void"), { method: "POST", body: JSON.stringify({ reason: "" }) }),
      "Masraf geri çekildi."
    );
  }

  const dialogs = (
    <>
      {reasonDialog}
      {confirmDialog}
    </>
  );

  return { busy, error, clearError: () => setError(null), approve, reject, voidExpense, withdraw, dialogs };
}

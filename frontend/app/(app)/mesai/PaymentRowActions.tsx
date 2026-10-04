"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { SalaryPayment } from "@/lib/types";

export function PaymentRowActions({ payment }: { payment: SalaryPayment }) {
  const router = useRouter();
  const [deleting, setDeleting] = useState(false);

  async function handleDelete() {
    // Para kaydı: onay penceresinde kime, ne kadar olduğu açıkça yazsın --
    // yanlış satıra tıklayıp başka bir ödemeyi silmek kolay.
    const who = payment.employee_name ?? "personel";
    if (
      !confirm(
        `${who} — ${formatTL(payment.amount)} (${payment.payment_type}) ödemesi silinsin mi?`
      )
    )
      return;
    setDeleting(true);
    try {
      await apiClient(`/api/v1/payroll/${payment.id}`, { method: "DELETE" });
      router.refresh();
    } catch (err) {
      alert(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setDeleting(false);
    }
  }

  return (
    <div className="flex justify-end">
      <Button
        variant="danger"
        disabled={deleting}
        onClick={handleDelete}
        className="px-2 py-1 text-xs"
      >
        {deleting ? "…" : "Sil"}
      </Button>
    </div>
  );
}

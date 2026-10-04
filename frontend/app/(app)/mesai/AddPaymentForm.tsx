"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL, istanbulDate, parseAmountTR } from "@/lib/format";
import type { PaymentType, SalaryPayment } from "@/lib/types";

export const PAYMENT_TYPES: PaymentType[] = ["maaş", "avans", "mesai", "prim", "diğer"];

const SELECT_CLASS =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold";

// Kalandan düşülmeyen türler -- backend PayrollSummaryByPeriod ile aynı küme.
const EXTRA_TYPES: PaymentType[] = ["prim", "diğer"];

// Ön doldurulan tutar parseAmountTR'nin okuduğu Türkçe yazımla: 1250.5 -> "1.250,5".
function amountInput(n: number): string {
  return n.toLocaleString("tr-TR", { maximumFractionDigits: 2 });
}

export function AddPaymentForm({
  employees,
  month,
  initialEmployeeId,
  initialAmount,
}: {
  // remaining: o ayın kalanı (ücret tanımsızsa null) -- seçilen personel
  // için formun altında gösterilir.
  employees: { id: string; full_name: string; remaining: number | null }[];
  month: string;
  // Tablodaki "Öde" düğmesinden gelince: personel seçili, tutar = kalan.
  initialEmployeeId?: string;
  initialAmount?: number;
}) {
  const router = useRouter();
  const [form, setForm] = useState({
    employee_id: initialEmployeeId ?? employees[0]?.id ?? "",
    payment_type: "maaş" as PaymentType,
    amount: initialAmount && initialAmount > 0 ? amountInput(initialAmount) : "",
    period: month,
    // İstanbul takvim günü -- toISOString() UTC'dir ve gece 00:00-03:00
    // arası bir önceki günü verirdi.
    paid_date: istanbulDate(new Date()),
    description: "",
  });
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!form.employee_id) {
      setError("Önce aktif personel eklemelisiniz.");
      return;
    }
    const amount = parseAmountTR(form.amount);
    if (!Number.isFinite(amount) || amount <= 0) {
      setError("Tutar sıfırdan büyük olmalı.");
      return;
    }
    setError(null);
    setLoading(true);
    try {
      await apiClient<SalaryPayment>("/api/v1/payroll", {
        method: "POST",
        body: JSON.stringify({
          employee_id: form.employee_id,
          period: form.period,
          payment_type: form.payment_type,
          amount,
          paid_date: form.paid_date,
          description: form.description,
        }),
      });
      setForm({ ...form, amount: "", description: "" });
      // "Öde" bağlantısının ?ode= parametresi temizlenir: yenilenen sayfa
      // formu aynı personelin eski kalanıyla yeniden doldurmasın.
      router.replace(`/mesai?month=${month}`, { scroll: false });
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  const selected = employees.find((e) => e.id === form.employee_id);
  const remaining = form.period === month ? selected?.remaining : undefined;

  return (
    <Card>
      <CardBody>
        <form id="odeme" onSubmit={handleSubmit} className="flex flex-wrap items-end gap-3">
          <div className="flex flex-col gap-1.5">
            <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
              Personel
            </label>
            <select
              value={form.employee_id}
              onChange={(e) => setForm({ ...form, employee_id: e.target.value })}
              className={SELECT_CLASS}
            >
              {employees.map((emp) => (
                <option key={emp.id} value={emp.id}>
                  {emp.full_name}
                </option>
              ))}
            </select>
          </div>
          <div className="flex flex-col gap-1.5">
            <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
              Tür
            </label>
            <select
              value={form.payment_type}
              onChange={(e) =>
                setForm({
                  ...form,
                  payment_type: e.target.value as PaymentType,
                })
              }
              className={SELECT_CLASS}
            >
              {PAYMENT_TYPES.map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
          </div>
          <Input
            label="Tutar (₺)"
            inputMode="decimal"
            required
            className="w-32"
            placeholder="0,00"
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <Input
            label="Ait olduğu ay"
            type="month"
            required
            value={form.period}
            onChange={(e) => setForm({ ...form, period: e.target.value })}
          />
          <Input
            label="Ödeme tarihi"
            type="date"
            required
            value={form.paid_date}
            onChange={(e) => setForm({ ...form, paid_date: e.target.value })}
          />
          <Input
            label="Açıklama"
            className="w-48"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading}>
            {loading ? "Kaydediliyor…" : "Ödeme Ekle"}
          </Button>
          {remaining != null && (
            <p className="basis-full text-xs text-text-muted">
              {selected?.full_name} — {month} kalanı:{" "}
              <span className="font-semibold text-text">
                {remaining > 0 ? formatTL(remaining) : "yok"}
              </span>
              {remaining < 0 && ` (${formatTL(-remaining)} fazla ödendi)`}
              {EXTRA_TYPES.includes(form.payment_type)
                ? ". Prim ve diğer kalandan düşmez."
                : ". Fazla ödeme sonraki aya devreder."}
            </p>
          )}
        </form>
      </CardBody>
    </Card>
  );
}

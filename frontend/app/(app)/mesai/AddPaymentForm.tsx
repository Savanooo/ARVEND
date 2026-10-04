"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { istanbulDate, parseAmountTR } from "@/lib/format";
import type { PaymentType, SalaryPayment } from "@/lib/types";

export const PAYMENT_TYPES: PaymentType[] = ["maaş", "avans", "mesai", "prim", "diğer"];

const SELECT_CLASS =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold";

export function AddPaymentForm({
  employees,
  month,
}: {
  employees: { id: string; full_name: string }[];
  month: string;
}) {
  const router = useRouter();
  const [form, setForm] = useState({
    employee_id: employees[0]?.id ?? "",
    payment_type: "maaş" as PaymentType,
    amount: "",
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
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-wrap items-end gap-3">
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
        </form>
      </CardBody>
    </Card>
  );
}

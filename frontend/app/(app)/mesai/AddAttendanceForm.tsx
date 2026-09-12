"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { AttendanceLog, AttendanceStatus, Employee } from "@/lib/types";

const STATUSES: AttendanceStatus[] = ["geldi", "yarım gün", "gelmedi", "izinli"];

function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

export function AddAttendanceForm({ employees }: { employees: Employee[] }) {
  const router = useRouter();
  const [form, setForm] = useState({
    employee_id: employees[0]?.id ?? "",
    date: todayISO(),
    check_in: "",
    check_out: "",
    work_hours: "",
    status: "geldi" as AttendanceStatus,
    note: "",
  });
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!form.employee_id) {
      setError("Önce aktif personel eklemelisiniz.");
      return;
    }
    setError(null);
    setLoading(true);
    try {
      await apiClient<AttendanceLog>("/api/v1/attendance", {
        method: "POST",
        body: JSON.stringify({
          employee_id: form.employee_id,
          date: form.date,
          check_in: form.check_in,
          check_out: form.check_out,
          work_hours: form.work_hours ? parseFloat(form.work_hours) : 0,
          status: form.status,
          note: form.note,
        }),
      });
      setForm({ ...form, check_in: "", check_out: "", work_hours: "", note: "" });
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
              className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
            >
              {employees.map((emp) => (
                <option key={emp.id} value={emp.id}>
                  {emp.full_name}
                </option>
              ))}
            </select>
          </div>
          <Input
            label="Tarih"
            type="date"
            required
            value={form.date}
            onChange={(e) => setForm({ ...form, date: e.target.value })}
          />
          <div className="flex flex-col gap-1.5">
            <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
              Durum
            </label>
            <select
              value={form.status}
              onChange={(e) => setForm({ ...form, status: e.target.value as AttendanceStatus })}
              className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
            >
              {STATUSES.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </div>
          <Input
            label="Giriş"
            type="time"
            value={form.check_in}
            onChange={(e) => setForm({ ...form, check_in: e.target.value })}
          />
          <Input
            label="Çıkış"
            type="time"
            value={form.check_out}
            onChange={(e) => setForm({ ...form, check_out: e.target.value })}
          />
          <Input
            label="Saat"
            type="number"
            step="0.5"
            min={0}
            className="w-20"
            value={form.work_hours}
            onChange={(e) => setForm({ ...form, work_hours: e.target.value })}
          />
          <Input
            label="Not"
            className="w-40"
            value={form.note}
            onChange={(e) => setForm({ ...form, note: e.target.value })}
          />
          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading}>
            {loading ? "Ekleniyor…" : "Ekle"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}

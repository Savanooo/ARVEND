"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { initialTimes, resolveWorkHours, statusHasHours } from "@/lib/attendance";
import { istanbulDate } from "@/lib/format";
import type { AttendanceLog, AttendanceStatus, Employee } from "@/lib/types";

import { AttendanceTimeFields } from "./AttendanceTimeFields";

const STATUSES: AttendanceStatus[] = ["geldi", "yarım gün", "gelmedi", "izinli"];

// "Bugün" İstanbul takvim günüdür (UTC değil: 00:00-03:00 arası dünü
// önermesin). Puantaj ileri tarihe girilmez.
function todayISO() {
  return istanbulDate(new Date());
}

export function AddAttendanceForm({ employees }: { employees: Employee[] }) {
  const router = useRouter();
  const toast = useToast();
  const [form, setForm] = useState({
    employee_id: employees[0]?.id ?? "",
    date: todayISO(),
    status: "geldi" as AttendanceStatus,
    note: "",
  });
  const [times, setTimes] = useState(() => initialTimes());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const hasHours = statusHasHours(form.status);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!form.employee_id) {
      setError("Önce aktif personel eklemelisiniz.");
      return;
    }
    if (form.date > todayISO()) {
      setError("İleri bir tarihe mesai girilemez.");
      return;
    }
    const workHours = hasHours ? resolveWorkHours(times) : 0;
    if (hasHours && !(workHours > 0 && workHours <= 24)) {
      setError("Çalışılan saat 0 ile 24 arasında olmalı; giriş-çıkış saatlerini ya da saati kontrol edin.");
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
          // Gelmedi/izinli günde giriş-çıkış ve saat anlamsız (mobil ile aynı).
          check_in: hasHours ? times.check_in : "",
          check_out: hasHours ? times.check_out : "",
          work_hours: workHours,
          status: form.status,
          note: form.note,
        }),
      });
      const name = employees.find((emp) => emp.id === form.employee_id)?.full_name;
      toast.success(`${name ? `${name} için ` : ""}${form.date} mesai kaydı eklendi.`);
      setForm({ ...form, note: "" });
      setTimes(initialTimes());
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
            max={todayISO()}
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
          {hasHours && <AttendanceTimeFields value={times} onChange={setTimes} idPrefix="new_attendance" />}
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

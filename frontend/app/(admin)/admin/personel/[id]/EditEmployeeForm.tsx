"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Employee } from "@/lib/types";

export function EditEmployeeForm({ employee }: { employee: Employee }) {
  const router = useRouter();
  const [form, setForm] = useState({
    full_name: employee.full_name,
    phone: employee.phone,
    position: employee.position,
    daily_wage: employee.daily_wage?.toString() ?? "",
    salary: employee.salary?.toString() ?? "",
    start_date: employee.start_date ?? "",
    description: employee.description,
    is_active: employee.is_active,
  });
  const [saving, setSaving] = useState(false);
  const [archiving, setArchiving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/employees/${employee.id}`, {
        method: "PUT",
        body: JSON.stringify({
          full_name: form.full_name,
          phone: form.phone,
          position: form.position,
          daily_wage: form.daily_wage ? parseFloat(form.daily_wage) : null,
          salary: form.salary ? parseFloat(form.salary) : null,
          start_date: form.start_date || null,
          description: form.description,
          is_active: form.is_active,
        }),
      });
      setMessage("Kaydedildi.");
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  async function handleArchive() {
    if (!confirm(`${employee.full_name} pasifleştirilsin mi?`)) return;
    setArchiving(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/employees/${employee.id}`, { method: "DELETE" });
      router.push("/admin/personel");
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setArchiving(false);
    }
  }

  return (
    <Card>
      <CardHeader>Personel Bilgileri</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input
            label="Ad Soyad"
            required
            value={form.full_name}
            onChange={(e) => setForm({ ...form, full_name: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Telefon"
              value={form.phone}
              onChange={(e) => setForm({ ...form, phone: e.target.value })}
            />
            <Input
              label="Görev"
              value={form.position}
              onChange={(e) => setForm({ ...form, position: e.target.value })}
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Günlük Yevmiye"
              type="number"
              step="0.01"
              min={0}
              value={form.daily_wage}
              onChange={(e) => setForm({ ...form, daily_wage: e.target.value })}
            />
            <Input
              label="Aylık Maaş"
              type="number"
              step="0.01"
              min={0}
              value={form.salary}
              onChange={(e) => setForm({ ...form, salary: e.target.value })}
            />
          </div>
          <Input
            label="İşe Başlama Tarihi"
            type="date"
            value={form.start_date}
            onChange={(e) => setForm({ ...form, start_date: e.target.value })}
          />
          <Input
            label="Açıklama"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <label className="flex items-center gap-2 text-sm text-text-muted">
            <input
              type="checkbox"
              checked={form.is_active}
              onChange={(e) => setForm({ ...form, is_active: e.target.checked })}
            />
            Aktif
          </label>
          {message && <p className="text-xs text-text-muted">{message}</p>}
          <div className="flex items-center gap-3">
            <Button type="submit" disabled={saving}>
              {saving ? "Kaydediliyor…" : "Kaydet"}
            </Button>
            {employee.is_active && (
              <Button type="button" variant="danger" disabled={archiving} onClick={handleArchive}>
                {archiving ? "Pasifleştiriliyor…" : "Pasifleştir"}
              </Button>
            )}
          </div>
        </form>
      </CardBody>
    </Card>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import type { Employee, User } from "@/lib/types";

export function EditEmployeeForm({
  employee,
  users,
  canManage,
  canLinkUsers,
}: {
  employee: Employee;
  users: User[];
  canManage: boolean;
  // Kullanıcı listesini göremeyen biri bağlantıyı değiştiremez; mevcut
  // bağlantı kaydedilirken olduğu gibi korunur.
  canLinkUsers: boolean;
}) {
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
    user_id: employee.user_id ?? "",
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
          user_id: form.user_id || "",
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

  const readOnly = !canManage;

  return (
    <Card>
      <CardHeader>Personel Bilgileri</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          {readOnly && (
            <p className="text-xs text-text-muted">
              Bu kaydı yalnızca görüntüleyebilirsin; düzenlemek için rolünde &quot;Personeli düzenleme&quot; izni olmalı.
            </p>
          )}
          <Input
            label="Ad Soyad"
            required
            disabled={readOnly}
            value={form.full_name}
            onChange={(e) => setForm({ ...form, full_name: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Telefon"
              disabled={readOnly}
              value={form.phone}
              onChange={(e) => setForm({ ...form, phone: e.target.value })}
            />
            <Input
              label="Görev"
              disabled={readOnly}
              value={form.position}
              onChange={(e) => setForm({ ...form, position: e.target.value })}
            />
          </div>
          {/* Ücretler yalnızca düzenleme yetkisiyle görünür: "Personeli
              görüntüleme" mesai girişi için de verilir, maaşları açmamalı. */}
          {!readOnly && (
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
          )}
          <Input
            label="İşe Başlama Tarihi"
            type="date"
            disabled={readOnly}
            value={form.start_date}
            onChange={(e) => setForm({ ...form, start_date: e.target.value })}
          />
          <Input
            label="Açıklama"
            disabled={readOnly}
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          {canLinkUsers ? (
            <>
              <Select
                label="Bağlı Kullanıcı Hesabı"
                disabled={readOnly}
                value={form.user_id}
                onChange={(e) => setForm({ ...form, user_id: e.target.value })}
              >
                <option value="">— Bağlantı yok —</option>
                {users.map((u) => (
                  <option key={u.id} value={u.id}>
                    {u.full_name} ({u.username})
                  </option>
                ))}
              </Select>
              <p className="-mt-2 text-xs text-text-muted">
                Bu personeli bir giriş hesabına bağlarsanız, o kullanıcı mobil uygulamada &quot;Görevlerim&quot;
                altında yalnızca kendisine atanan görevleri görebilir.
              </p>
            </>
          ) : (
            <p className="text-xs text-text-muted">
              Bağlı kullanıcı hesabı: {employee.user_id ? "var" : "yok"} (değiştirmek için kullanıcıları görme izni gerekir).
            </p>
          )}
          <label className="flex items-center gap-2 text-sm text-text-muted">
            <input
              type="checkbox"
              disabled={readOnly}
              checked={form.is_active}
              onChange={(e) => setForm({ ...form, is_active: e.target.checked })}
            />
            Aktif
          </label>
          {message && <p className="text-xs text-text-muted">{message}</p>}
          {!readOnly && (
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
          )}
        </form>
      </CardBody>
    </Card>
  );
}

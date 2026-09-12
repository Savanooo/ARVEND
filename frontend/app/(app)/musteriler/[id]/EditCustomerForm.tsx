"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Customer } from "@/lib/types";

export function EditCustomerForm({ customer }: { customer: Customer }) {
  const router = useRouter();
  const [form, setForm] = useState({
    name: customer.name,
    phone: customer.phone,
    email: customer.email,
    address: customer.address,
    tax_office: customer.tax_office,
    tax_number: customer.tax_number,
    notes: customer.notes,
    is_active: customer.is_active,
  });
  const [saving, setSaving] = useState(false);
  const [archiving, setArchiving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/customers/${customer.id}`, {
        method: "PUT",
        body: JSON.stringify(form),
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
    if (!confirm(`${customer.name} pasifleştirilsin mi?`)) return;
    setArchiving(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/customers/${customer.id}`, { method: "DELETE" });
      router.push("/musteriler");
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setArchiving(false);
    }
  }

  return (
    <Card>
      <CardHeader>Müşteri Bilgileri</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input
            label="Müşteri Adı"
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Telefon"
              value={form.phone}
              onChange={(e) => setForm({ ...form, phone: e.target.value })}
            />
            <Input
              label="E-posta"
              type="email"
              value={form.email}
              onChange={(e) => setForm({ ...form, email: e.target.value })}
            />
          </div>
          <Input
            label="Adres"
            value={form.address}
            onChange={(e) => setForm({ ...form, address: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Vergi Dairesi"
              value={form.tax_office}
              onChange={(e) => setForm({ ...form, tax_office: e.target.value })}
            />
            <Input
              label="Vergi No"
              value={form.tax_number}
              onChange={(e) => setForm({ ...form, tax_number: e.target.value })}
            />
          </div>
          <Input
            label="Not"
            value={form.notes}
            onChange={(e) => setForm({ ...form, notes: e.target.value })}
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
            {customer.is_active && (
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

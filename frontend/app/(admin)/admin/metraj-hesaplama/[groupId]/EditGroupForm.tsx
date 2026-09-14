"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";
import type { CalcGroup } from "@/lib/types";

export function EditGroupForm({ group }: { group: CalcGroup }) {
  const router = useRouter();
  const [form, setForm] = useState({
    slug: group.slug,
    name: group.name,
    description: group.description,
    sort_order: group.sort_order,
    is_active: group.is_active,
  });
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/calculations/groups/${group.id}`, {
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

  return (
    <Card>
      <CardHeader>Grup Bilgileri</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-3">
            <Input label="Ad" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <Input label="Slug" required value={form.slug} onChange={(e) => setForm({ ...form, slug: e.target.value })} />
          </div>
          <Textarea
            label="Açıklama"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Sıra"
              type="number"
              value={form.sort_order}
              onChange={(e) => setForm({ ...form, sort_order: parseInt(e.target.value, 10) || 0 })}
            />
            <label className="flex items-end gap-2 pb-2 text-sm text-text">
              <input
                type="checkbox"
                checked={form.is_active}
                onChange={(e) => setForm({ ...form, is_active: e.target.checked })}
              />
              Aktif (Metraj Hesapla panelinde görünür)
            </label>
          </div>
          {message && <p className="text-xs text-text-muted">{message}</p>}
          <Button type="submit" disabled={saving} className="w-fit">
            {saving ? "Kaydediliyor…" : "Kaydet"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}

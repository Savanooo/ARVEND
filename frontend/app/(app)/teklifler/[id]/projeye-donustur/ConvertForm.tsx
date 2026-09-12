"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { Offer, Project } from "@/lib/types";

export function ConvertForm({ offer }: { offer: Offer }) {
  const router = useRouter();
  const [form, setForm] = useState({
    // Varsayılan proje adı kabul edilen teklifin müşterisinden türetilir.
    name: `${offer.customer_name} - ${offer.offer_no}`,
    project_type: "",
    start_date: "",
    end_date: "",
    description: "",
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError(null);
    try {
      const project = await apiClient<Project>(`/api/v1/projects/from-offer/${offer.id}`, {
        method: "POST",
        body: JSON.stringify({
          ...form,
          start_date: form.start_date || null,
          end_date: form.end_date || null,
        }),
      });
      router.push(`/projeler/${project.id}`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-6 p-8 lg:flex-row">
      <div className="flex flex-1 flex-col gap-6">
        <Card>
          <CardHeader>Proje Bilgileri</CardHeader>
          <CardBody className="flex flex-col gap-4">
            <Input
              label="Proje Adı"
              required
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
            />
            <Input
              label="Proje Tipi"
              placeholder="örn. İnşaat, Tadilat, Altyapı"
              value={form.project_type}
              onChange={(e) => setForm({ ...form, project_type: e.target.value })}
            />
            <div className="flex gap-4">
              <Input
                label="Başlangıç Tarihi"
                type="date"
                className="flex-1"
                value={form.start_date}
                onChange={(e) => setForm({ ...form, start_date: e.target.value })}
              />
              <Input
                label="Planlanan Bitiş"
                type="date"
                className="flex-1"
                value={form.end_date}
                onChange={(e) => setForm({ ...form, end_date: e.target.value })}
              />
            </div>
            <Input
              label="Açıklama"
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
            />
            {error && <p className="text-sm text-danger">{error}</p>}
            <div>
              <Button type="submit" disabled={saving}>
                {saving ? "Oluşturuluyor…" : "Projeyi Oluştur"}
              </Button>
            </div>
          </CardBody>
        </Card>
      </div>

      <div className="flex w-full flex-col gap-6 lg:w-80">
        <Card className="h-fit">
          <CardHeader>Tekliften Gelen Bilgiler</CardHeader>
          <CardBody className="flex flex-col gap-3 text-sm">
            <div>
              <div className="text-xs uppercase tracking-widest text-text-muted">Teklif</div>
              <div>
                {offer.offer_no} · Revizyon {offer.revision_no}
              </div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-widest text-text-muted">Müşteri</div>
              <div>{offer.customer_name}</div>
              {offer.customer_phone && (
                <div className="text-text-muted">{offer.customer_phone}</div>
              )}
              {offer.customer_email && (
                <div className="text-text-muted">{offer.customer_email}</div>
              )}
            </div>
            <div>
              <div className="text-xs uppercase tracking-widest text-text-muted">
                Sözleşme Bedeli
              </div>
              <div className="font-medium">{formatTL(offer.grand_total)}</div>
            </div>
            <p className="border-t border-border pt-3 text-xs text-text-muted">
              Müşteri bilgileri ve sözleşme bedeli, kabul edilen revizyondan anlık görüntü olarak
              kopyalanır; teklif tarafında sonradan bir şey değişse bile proje etkilenmez.
            </p>
          </CardBody>
        </Card>
      </div>
    </form>
  );
}

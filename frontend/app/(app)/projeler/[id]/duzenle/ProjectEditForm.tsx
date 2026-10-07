"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import { PROJECT_STATUS_LABELS, type Project, type ProjectStatus } from "@/lib/types";

// Duruma göre izin verilen geçişler -- backend'deki kuralın aynası
// (domain/project.go projectTransitions; asıl kontrol serviste, burası
// sadece kullanıcıya imkansız seçeneği göstermemek için). Tamamlanmış proje
// bilinçli olarak yeniden "Devam Ediyor"a alınabilir (finans hareketi
// girmek için); iptal edilen proje terminaldir.
const TRANSITIONS: Record<ProjectStatus, ProjectStatus[]> = {
  planned: ["planned", "active", "paused", "cancelled"],
  active: ["active", "paused", "completed", "cancelled"],
  paused: ["paused", "active", "completed", "cancelled"],
  completed: ["completed", "active"],
  cancelled: ["cancelled"],
};

export function ProjectEditForm({ project }: { project: Project }) {
  const router = useRouter();
  const { confirm, dialog } = useConfirmDialog();
  const [form, setForm] = useState({
    name: project.name,
    project_type: project.project_type,
    status: project.status,
    start_date: project.start_date ?? "",
    end_date: project.end_date ?? "",
    description: project.description,
    internal_notes: project.internal_notes,
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (project.status === "completed" && form.status === "active") {
      const ok = await confirm({
        title: "Projeyi yeniden aç",
        message:
          "Tamamlanmış proje yeniden \"Devam Ediyor\" durumuna alınacak; finans hareketlerinin kilidi açılır ve tahsilat, masraf, fatura girilebilir. İş bittiğinde projeyi tekrar Tamamlandı yapabilirsiniz.",
        confirmLabel: "Yeniden Aç",
      });
      if (!ok) return;
    }
    setSaving(true);
    setError(null);
    try {
      await apiClient(`/api/v1/projects/${project.id}`, {
        method: "PUT",
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
    <>
      {/* Onay penceresi formun DIŞINDA: içindeki düğmeler formu göndermesin. */}
      {dialog}
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
              <div className="flex flex-col gap-1.5">
                <Select
                  label="Durum"
                  value={form.status}
                  onChange={(e) => setForm({ ...form, status: e.target.value as ProjectStatus })}
                >
                  {TRANSITIONS[project.status].map((s) => (
                    <option key={s} value={s}>
                      {PROJECT_STATUS_LABELS[s]}
                    </option>
                  ))}
                </Select>
                {TRANSITIONS[project.status].length === 1 && (
                  <p className="text-xs text-text-muted">
                    {PROJECT_STATUS_LABELS[project.status]} durumundaki bir proje yeniden
                    açılamaz.
                  </p>
                )}
                {project.status === "completed" && (
                  <p className="text-xs text-text-muted">
                    Tamamlanmış projede finans hareketleri kilitlidir; hareket girmek için
                    projeyi &quot;{PROJECT_STATUS_LABELS.active}&quot; durumuna alarak yeniden açabilirsiniz.
                  </p>
                )}
              </div>
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
              <Input
                label="Dahili Notlar (müşteri görmez)"
                value={form.internal_notes}
                onChange={(e) => setForm({ ...form, internal_notes: e.target.value })}
              />
              {error && <p className="text-sm text-danger">{error}</p>}
              <div className="flex gap-2">
                <Button type="submit" disabled={saving}>
                  {saving ? "Kaydediliyor…" : "Değişiklikleri Kaydet"}
                </Button>
              </div>
            </CardBody>
          </Card>
        </div>

        <div className="flex w-full flex-col gap-6 lg:w-80">
          <Card className="h-fit">
            <CardHeader>Değiştirilemeyen Bilgiler</CardHeader>
            <CardBody className="flex flex-col gap-3 text-sm">
              <div>
                <div className="text-xs uppercase tracking-widest text-text-muted">Proje No</div>
                <div>{project.project_no}</div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-widest text-text-muted">Müşteri</div>
                <div>{project.customer_name}</div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-widest text-text-muted">
                  Sözleşme Bedeli
                </div>
                <div>
                  {formatTL(project.contract_amount)} {project.currency}
                </div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-widest text-text-muted">Kaynak Teklif</div>
                <div>
                  {project.source_offer_no} · Revizyon {project.source_revision_no}
                </div>
              </div>
              <p className="border-t border-border pt-3 text-xs text-text-muted">
                Bu alanlar kabul edilen teklife ait dondurulmuş bilgilerdir. Sözleşme bedeli
                değişiklikleri ileride &quot;Ek İşler&quot; modülüyle yapılacak.
              </p>
            </CardBody>
          </Card>
        </div>
      </form>
    </>
  );
}

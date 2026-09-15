"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Select } from "@/components/ui/Select";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { apiClient, ApiError } from "@/lib/api";
import { ORG_STATUS_LABELS, type Organization, type OrgStatus, type Plan } from "@/lib/types";

export function GeneralTab({ organization, plans }: { organization: Organization; plans: Plan[] }) {
  const router = useRouter();
  const { confirm, dialog } = useConfirmDialog();
  const [status, setStatus] = useState<OrgStatus>(organization.status);
  const [planCode, setPlanCode] = useState(organization.plan_code);
  const [savingStatus, setSavingStatus] = useState(false);
  const [savingPlan, setSavingPlan] = useState(false);
  const [reprovisioning, setReprovisioning] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleStatusUpdate() {
    setError(null);
    setMessage(null);
    if (status === "suspended") {
      const ok = await confirm({
        title: "Firmayı askıya al",
        message: `${organization.name} askıya alınacak -- tüm kullanıcıları (halihazırda oturum açmış olanlar dahil) hemen erişimi kaybeder. Devam edilsin mi?`,
        confirmLabel: "Askıya Al",
        danger: true,
      });
      if (!ok) return;
    }
    setSavingStatus(true);
    try {
      await apiClient<Organization>(`/api/v1/platform/organizations/${organization.id}/status`, {
        method: "PATCH",
        body: JSON.stringify({ status }),
      });
      setMessage("Durum güncellendi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingStatus(false);
    }
  }

  async function handlePlanUpdate() {
    setError(null);
    setMessage(null);
    setSavingPlan(true);
    try {
      await apiClient<Organization>(`/api/v1/platform/organizations/${organization.id}/plan`, {
        method: "PATCH",
        body: JSON.stringify({ plan_code: planCode }),
      });
      setMessage("Plan güncellendi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingPlan(false);
    }
  }

  async function handleReprovision() {
    setError(null);
    setMessage(null);
    setReprovisioning(true);
    try {
      const res = await apiClient<{
        groups_created: number;
        categories_created: number;
        items_created: number;
      }>(`/api/v1/platform/organizations/${organization.id}/reprovision-calc-catalog`, {
        method: "POST",
        body: JSON.stringify({ link_products: false }),
      });
      setMessage(
        `Katalog kontrol edildi: ${res.groups_created} grup, ${res.categories_created} kategori, ${res.items_created} kalem eklendi (zaten var olanlar atlandı).`
      );
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setReprovisioning(false);
    }
  }

  return (
    <div className="flex flex-col gap-4 pt-2">
      <Card>
        <CardHeader>Firma Bilgileri</CardHeader>
        <CardBody className="flex flex-col gap-2 text-sm">
          <InfoRow label="Slug" value={organization.slug} />
          <InfoRow
            label="Onboarding"
            value={organization.onboarding_completed ? "Tamamlandı" : `Devam ediyor (${organization.onboarding_step})`}
          />
          {organization.trial_ends_at && (
            <InfoRow label="Deneme Bitiş" value={new Date(organization.trial_ends_at).toLocaleDateString("tr-TR")} />
          )}
          <InfoRow label="Oluşturulma" value={new Date(organization.created_at).toLocaleString("tr-TR")} />
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Durum ve Plan</CardHeader>
        <CardBody className="flex flex-col gap-4">
          <div className="flex items-end gap-3">
            <Select
              label="Durum"
              value={status}
              onChange={(e) => setStatus(e.target.value as OrgStatus)}
              className="flex-1"
            >
              {(Object.keys(ORG_STATUS_LABELS) as OrgStatus[]).map((s) => (
                <option key={s} value={s}>
                  {ORG_STATUS_LABELS[s]}
                </option>
              ))}
            </Select>
            <Button
              type="button"
              variant={status === "suspended" ? "danger" : "primary"}
              disabled={savingStatus || status === organization.status}
              onClick={handleStatusUpdate}
            >
              {savingStatus ? "Güncelleniyor…" : "Güncelle"}
            </Button>
          </div>
          <div className="flex items-end gap-3">
            <Select label="Plan" value={planCode} onChange={(e) => setPlanCode(e.target.value)} className="flex-1">
              {plans.map((p) => (
                <option key={p.code} value={p.code}>
                  {p.name}
                </option>
              ))}
            </Select>
            <Button
              type="button"
              variant="secondary"
              disabled={savingPlan || planCode === organization.plan_code}
              onClick={handlePlanUpdate}
            >
              {savingPlan ? "Güncelleniyor…" : "Güncelle"}
            </Button>
          </div>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Metraj Hesaplama Kataloğu</CardHeader>
        <CardBody className="flex flex-col gap-3">
          <p className="text-xs text-text-muted">
            Varsayılan grup/kategori/reçete kataloğunu bu firma için yeniden kontrol eder -- zaten var olan
            satırlar atlanır, yalnızca eksik olanlar eklenir (idempotent, güvenle tekrar çalıştırılabilir).
          </p>
          <Button type="button" variant="secondary" disabled={reprovisioning} onClick={handleReprovision} className="self-start">
            {reprovisioning ? "Kontrol ediliyor…" : "Kataloğu Kontrol Et / Tamamla"}
          </Button>
        </CardBody>
      </Card>

      {message && <p className="text-xs text-success">{message}</p>}
      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">{label}</span>
      <span className="text-text">{value}</span>
    </div>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Select } from "@/components/ui/Select";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { orgLifecycleActions, type OrgLifecycleAction } from "@/lib/org-lifecycle";
import { ORG_STATUS } from "@/lib/status";
import { ONBOARDING_STEP_LABELS, type Organization, type Plan } from "@/lib/types";

export function GeneralTab({
  organization,
  plans,
  userCount,
  activeOwnerCount,
}: {
  organization: Organization;
  plans: Plan[];
  userCount: number;
  activeOwnerCount: number;
}) {
  const router = useRouter();
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const [planCode, setPlanCode] = useState(organization.plan_code);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const planName = plans.find((p) => p.code === organization.plan_code)?.name ?? organization.plan_code;
  const actions = orgLifecycleActions(organization.status);
  // GET /platform/plans yalnızca is_active=true planları döner; firma daha
  // sonra pasifleştirilmiş bir planda kalmış olabilir. Böyle bir kodu
  // seçenek listesinden düşürmek denetlenen &lt;select&gt;'i value'suyla
  // eşleşmeyen bir DOM seçimine düşürür (tarayıcı ilk aktif planı
  // gösterir, "Planı Güncelle" ise "değişmedi" sanıp devre dışı kalır) --
  // mevcut plan listede yoksa başa EKLENIR ki gerçek durum her zaman
  // görünür ve seçili kalsın.
  const planOptions = plans.some((p) => p.code === organization.plan_code)
    ? plans
    : [{ code: organization.plan_code, name: `${planName} (pasif plan)`, is_active: false, max_users: 0, max_projects: 0, sort_order: -1 }, ...plans];

  async function runLifecycle(action: OrgLifecycleAction) {
    setError(null);
    const ok = await confirm({
      title: `${action.label}: ${organization.name}`,
      message: action.description,
      confirmLabel: action.label,
      danger: action.danger,
    });
    if (!ok) return;
    setBusy(action.target);
    try {
      await apiClient<Organization>(`/api/v1/platform/organizations/${organization.id}/status`, {
        method: "PATCH",
        body: JSON.stringify({ status: action.target }),
      });
      toast.success(`Firma durumu güncellendi: ${ORG_STATUS[action.target].label}`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(null);
    }
  }

  async function handlePlanUpdate() {
    setError(null);
    setBusy("plan");
    try {
      await apiClient<Organization>(`/api/v1/platform/organizations/${organization.id}/plan`, {
        method: "PATCH",
        body: JSON.stringify({ plan_code: planCode }),
      });
      toast.success("Plan güncellendi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(null);
    }
  }

  async function handleReprovision() {
    setError(null);
    setBusy("catalog");
    try {
      const res = await apiClient<{ groups_created: number; categories_created: number; items_created: number }>(
        `/api/v1/platform/organizations/${organization.id}/reprovision-calc-catalog`,
        { method: "POST", body: JSON.stringify({ link_products: false }) }
      );
      toast.success(
        `Katalog kontrol edildi: ${res.groups_created} grup, ${res.categories_created} kategori, ${res.items_created} kalem eklendi.`
      );
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="flex flex-col gap-4 pt-2">
      <Card>
        <CardHeader>Firma Bilgileri</CardHeader>
        <CardBody className="flex flex-col gap-2 text-sm">
          <InfoRow label="Durum">
            <StatusBadge status={organization.status} registry={ORG_STATUS} />
          </InfoRow>
          <InfoRow label="Plan">{planName}</InfoRow>
          <InfoRow label="Slug">{organization.slug}</InfoRow>
          <InfoRow label="Onboarding">
            {organization.onboarding_completed
              ? "Tamamlandı"
              : `Devam ediyor · ${ONBOARDING_STEP_LABELS[organization.onboarding_step] ?? organization.onboarding_step}`}
          </InfoRow>
          <InfoRow label="Kullanıcı">{userCount}</InfoRow>
          <InfoRow label="Aktif Sahip">
            {activeOwnerCount > 0 ? (
              activeOwnerCount
            ) : (
              <span className="text-danger">Yok — Kullanıcılar sekmesinden bir Sahip tanımlayın</span>
            )}
          </InfoRow>
          {organization.status === "trial" && organization.trial_ends_at && (
            <InfoRow label="Deneme Bitiş">{new Date(organization.trial_ends_at).toLocaleDateString("tr-TR")}</InfoRow>
          )}
          <InfoRow label="Oluşturulma">{new Date(organization.created_at).toLocaleString("tr-TR")}</InfoRow>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Yaşam Döngüsü</CardHeader>
        <CardBody className="flex flex-col gap-3">
          <p className="text-xs text-text-muted">
            Firma silinmez; askıya alma ve iptal yalnızca erişimi kapatır, tüm kayıtlar korunur ve her iki
            durumdan da yeniden aktifleştirilebilir. Her işlem onay ister.
          </p>
          {actions.length === 0 ? (
            <p className="text-xs text-text-muted">Bu durumda yapılabilecek bir işlem yok.</p>
          ) : (
            <div className="flex flex-wrap gap-2">
              {actions.map((action) => (
                <Button
                  key={action.target}
                  type="button"
                  variant={action.danger ? "danger" : "primary"}
                  disabled={busy !== null}
                  onClick={() => runLifecycle(action)}
                >
                  {busy === action.target ? "Uygulanıyor…" : action.label}
                </Button>
              ))}
            </div>
          )}
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Plan</CardHeader>
        <CardBody>
          <div className="flex items-end gap-3">
            <Select label="Plan" value={planCode} onChange={(e) => setPlanCode(e.target.value)} className="flex-1">
              {planOptions.map((p) => (
                <option key={p.code} value={p.code}>
                  {p.name}
                </option>
              ))}
            </Select>
            <Button
              type="button"
              variant="secondary"
              disabled={busy !== null || planCode === organization.plan_code}
              onClick={handlePlanUpdate}
            >
              {busy === "plan" ? "Güncelleniyor…" : "Planı Güncelle"}
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
          <Button type="button" variant="secondary" disabled={busy !== null} onClick={handleReprovision} className="self-start">
            {busy === "catalog" ? "Kontrol ediliyor…" : "Kataloğu Kontrol Et / Tamamla"}
          </Button>
        </CardBody>
      </Card>

      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}
    </div>
  );
}

function InfoRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">{label}</span>
      <span className="text-right text-text">{children}</span>
    </div>
  );
}

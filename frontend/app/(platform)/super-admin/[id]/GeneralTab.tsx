"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
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
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);

  const deleted = Boolean(organization.deleted_at);
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

  // Restore, silme ile TAMAMEN AYRI bir eksendir (durum/plan işlemleri
  // İLE karıştırılmamalı) -- "Firmayı Geri Yükle" kasıtlı olarak Tehlikeli
  // İşlemler kartında, "Firmayı Sil"in yerini alarak gösterilir: ikisi de
  // AYNI danger-zone konumunda ama Geri Yükle yıkıcı DEĞİLDİR (primary).
  async function handleRestore() {
    setError(null);
    setBusy("restore");
    try {
      await apiClient(`/api/v1/platform/organizations/${organization.id}/restore`, { method: "POST" });
      toast.success("Firma geri yüklendi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(null);
    }
  }

  async function handleDelete() {
    setBusy("delete");
    try {
      await apiClient(`/api/v1/platform/organizations/${organization.id}/delete`, { method: "POST" });
      setShowDeleteDialog(false);
      toast.success("Firma silindi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      throw err;
    } finally {
      setBusy(null);
    }
  }

  // İptal Et (yalnızca gerçekten "danger" olan aksiyon) diğerlerinden
  // ayrı, alttaki bir bölüme render edilir -- "visually separated"
  // gerekliliği; Askıya Al/Aktifleştir/Yeniden Aktifleştir üstteki normal
  // sırada kalır (bkz. lib/org-lifecycle.ts buttonVariant yorumu).
  const cancelAction = actions.find((a) => a.buttonVariant === "danger");
  const primaryActions = actions.filter((a) => a.buttonVariant !== "danger");

  return (
    <div className="flex flex-col gap-5 pt-2">
      {deleted && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-danger/40 bg-danger/5 px-4 py-3 text-sm">
          <span>
            Bu firma <strong>silinmiş</strong>: erişimi kapalı ve normal listelerde görünmüyor. Tüm verileri
            korunuyor. Durum/plan/kullanıcı işlemleri için önce geri yükleyin.
          </span>
          <Button type="button" disabled={busy !== null} onClick={handleRestore}>
            {busy === "restore" ? "Geri yükleniyor…" : "Firmayı Geri Yükle"}
          </Button>
        </div>
      )}
      <div className="grid grid-cols-1 gap-5 lg:grid-cols-2 lg:items-start">
        <Card>
          <CardHeader>Firma Bilgileri</CardHeader>
          <CardBody className="flex flex-col gap-2 text-sm">
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
                <span className="text-danger">Yok — Kullanıcılar sekmesinden bir Sahip oluşturun</span>
              )}
            </InfoRow>
            {organization.status === "trial" && organization.trial_ends_at && (
              <InfoRow label="Deneme Bitiş">{new Date(organization.trial_ends_at).toLocaleDateString("tr-TR")}</InfoRow>
            )}
            <InfoRow label="Oluşturulma">{new Date(organization.created_at).toLocaleString("tr-TR")}</InfoRow>
          </CardBody>
        </Card>

        <div className="flex flex-col gap-5">
          <Card>
            <CardHeader>Plan</CardHeader>
            <CardBody className="flex flex-col gap-3">
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
                  disabled={deleted || busy !== null || planCode === organization.plan_code}
                  onClick={handlePlanUpdate}
                >
                  {busy === "plan" ? "Güncelleniyor…" : "Güncelle"}
                </Button>
              </div>
            </CardBody>
          </Card>

          <Card>
            <CardHeader>Durum ve Yaşam Döngüsü</CardHeader>
            <CardBody className="flex flex-col gap-4">
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">Mevcut Durum</span>
                <StatusBadge status={organization.status} registry={ORG_STATUS} />
              </div>
              <p className="text-xs text-text-muted">
                Firma silinmez; askıya alma ve iptal yalnızca erişimi kapatır, tüm kayıtlar korunur ve her iki
                durumdan da yeniden aktifleştirilebilir.
              </p>
              {deleted ? (
                <p className="text-xs text-text-muted">
                  Firma silinmiş durumda -- yaşam döngüsü işlemleri için önce geri yükleyin (yukarıdaki uyarı).
                </p>
              ) : actions.length === 0 ? (
                <p className="text-xs text-text-muted">Bu durumda yapılabilecek bir işlem yok.</p>
              ) : (
                <>
                  {primaryActions.length > 0 && (
                    <div className="flex flex-wrap gap-2">
                      {primaryActions.map((action) => (
                        <Button
                          key={action.target}
                          type="button"
                          variant={action.buttonVariant}
                          disabled={busy !== null}
                          onClick={() => runLifecycle(action)}
                        >
                          {busy === action.target ? "Uygulanıyor…" : action.label}
                        </Button>
                      ))}
                    </div>
                  )}
                  {cancelAction && (
                    <div className={`flex ${primaryActions.length > 0 ? "border-t border-border pt-4" : ""}`}>
                      <Button
                        type="button"
                        variant="danger"
                        disabled={busy !== null}
                        onClick={() => runLifecycle(cancelAction)}
                      >
                        {busy === cancelAction.target ? "Uygulanıyor…" : cancelAction.label}
                      </Button>
                    </div>
                  )}
                </>
              )}
            </CardBody>
          </Card>
        </div>
      </div>

      <Card>
        <CardHeader>Platform Bakım Araçları</CardHeader>
        <CardBody className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex flex-col gap-1">
            <p className="text-sm font-medium">Metraj Hesaplama Kataloğu</p>
            <p className="max-w-xl text-xs text-text-muted">
              Varsayılan grup/kategori/reçete kataloğunu bu firma için yeniden kontrol eder -- zaten var olan
              satırlar atlanır, yalnızca eksik olanlar eklenir (idempotent, güvenle tekrar çalıştırılabilir).
            </p>
          </div>
          <Button type="button" variant="secondary" disabled={deleted || busy !== null} onClick={handleReprovision}>
            {busy === "catalog" ? "Kontrol ediliyor…" : "Kataloğu Kontrol Et / Tamamla"}
          </Button>
        </CardBody>
      </Card>

      {/* Tehlikeli İşlemler -- BİLİNÇLİ OLARAK durum/plan düğmelerinden
          UZAK, en altta, ayrı ve kırmızı çerçeveli kendi kartında (bkz.
          görev notu: "Do not place it next to normal plan/status
          buttons"). Firma zaten silinmişse Geri Yükle üstteki uyarı
          bandında yaşar -- burada tekrarlanmaz. */}
      {!deleted && (
        <Card className="border-danger/40">
          <CardHeader className="text-danger">Tehlikeli İşlemler</CardHeader>
          <CardBody className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex flex-col gap-1">
              <p className="text-sm font-medium">Firmayı Sil</p>
              <p className="max-w-xl text-xs text-text-muted">
                Firma normal listelerden kaldırılır ve kullanıcılarının erişimi kapatılır. Proje/teklif/finans ve
                diğer geçmiş kayıtlar fiziksel olarak SİLİNMEZ; işlem geri alınabilir.
              </p>
            </div>
            <Button type="button" variant="danger" onClick={() => setShowDeleteDialog(true)}>
              Firmayı Sil
            </Button>
          </CardBody>
        </Card>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}
      {showDeleteDialog && (
        <DeleteOrganizationDialog
          organization={organization}
          busy={busy === "delete"}
          onClose={() => setShowDeleteDialog(false)}
          onConfirm={handleDelete}
        />
      )}
    </div>
  );
}

// DeleteOrganizationDialog, firma adının AYNEN yazılmasını zorunlu kılar --
// "Require the organization name to be typed before confirming if
// practical" (görev notu). Kalıcı bir silme İZLENİMİ vermemek için metin
// her zaman "veriler korunur/geri alınabilir" der; buton yine de kırmızı
// (danger) kalır çünkü erişimi HEMEN kapatan, kolayca fark edilmesi
// gereken bir eylemdir.
function DeleteOrganizationDialog({
  organization,
  busy,
  onClose,
  onConfirm,
}: {
  organization: Organization;
  busy: boolean;
  onClose: () => void;
  onConfirm: () => Promise<void>;
}) {
  const [typed, setTyped] = useState("");
  const matches = typed.trim() === organization.name;

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!matches) return;
    try {
      await onConfirm();
    } catch {
      // Hata GeneralTab'in kendi {error} satırında zaten gösterilir --
      // diyalog burada kasıtlı olarak açık kalır (kullanıcı tekrar
      // deneyebilsin, girdiği ismi kaybetmesin).
    }
  }

  return (
    <Modal open onClose={onClose} title={`${organization.name} silinsin mi?`}>
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        <ul className="list-disc space-y-1 pl-5 text-xs text-text-muted">
          <li>Firma normal listelerden kaldırılacak.</li>
          <li>Firma kullanıcılarının erişimi kapatılacak.</li>
          <li>Proje, teklif, finans ve diğer geçmiş kayıtlar fiziksel olarak silinmeyecek.</li>
          <li>İşlem platform kayıtlarına yazılacak.</li>
        </ul>
        <div className="flex flex-col gap-1.5">
          <label className="text-xs text-text-muted">
            Onaylamak için firma adını yazın: <Badge tone="muted">{organization.name}</Badge>
          </label>
          <Input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" autoFocus />
        </div>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Vazgeç
          </Button>
          <Button type="submit" variant="danger" disabled={!matches || busy}>
            {busy ? "Siliniyor…" : "Firmayı Sil"}
          </Button>
        </div>
      </form>
    </Modal>
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

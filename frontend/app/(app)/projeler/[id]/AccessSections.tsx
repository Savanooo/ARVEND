"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import {
  ORG_ROLE_LABELS,
  PROJECT_ROLE_LABELS,
  type OrgUserOption,
  type Project,
  type ProjectAccessUser,
  type ProjectRole,
} from "@/lib/types";

// ---------- Proje Erişimi ----------
//
// project_users (RBAC/Project Membership sprint'i) — mevcut "Personel /
// Ekip" bölümünün (OperationSections.tsx'teki MembersSection, employee_id'ye
// bağlı İK/puantaj roster'ı) TAMAMEN AYRI bir kavramıdır: burası UYGULAMA
// KULLANICILARININ (login hesabı olan) bu projeye erişip erişemeyeceğini
// yönetir. Yalnızca owner/admin/legacy_user/project_manager (projects.
// access.read izniyle) görebilir; ekleme/çıkarma/rol değiştirme
// projects.access.manage ister (yalnızca owner/admin/legacy_user — bkz.
// backend permission registry) — bu ekran o kullanıcılara boş dönebilir,
// backend zaten 403 üretir; formu yalnızca izinli kullanıcı görür ama
// buton her durumda gösterilir (backend nihai sınırdır).

export function ProjectAccessSection({
  project,
  users,
  orgUsers,
}: {
  project: Project;
  users: ProjectAccessUser[];
  orgUsers: OrgUserOption[];
}) {
  const router = useRouter();
  const { confirm, dialog } = useConfirmDialog();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState<{ user_id: string; project_role: ProjectRole }>({
    user_id: "",
    project_role: "member",
  });

  const assignedIds = new Set(users.map((u) => u.user_id));
  const available = orgUsers.filter((u) => u.is_active !== false && !assignedIds.has(u.id));

  async function run(fn: () => Promise<unknown>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
      router.refresh();
      return true;
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/access`, {
        method: "POST",
        body: JSON.stringify(form),
      })
    );
    if (ok) setForm({ user_id: "", project_role: "member" });
  }

  async function changeRole(userId: string, projectRole: ProjectRole) {
    await run(() =>
      apiClient(`/api/v1/projects/${project.id}/access/${userId}`, {
        method: "PUT",
        body: JSON.stringify({ project_role: projectRole }),
      })
    );
  }

  async function remove(u: ProjectAccessUser) {
    if (!(await confirm({
      title: "Erişimi Kaldır",
      message: `${u.full_name} adlı kullanıcının bu projeye erişimi kaldırılsın mı?`,
      confirmLabel: "Kaldır",
      danger: true,
    }))) {
      return;
    }
    await run(() => apiClient(`/api/v1/projects/${project.id}/access/${u.user_id}`, { method: "DELETE" }));
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-xs text-text-muted">
        Sahip/Yönetici rolündeki kullanıcılar tüm projeleri koşulsuz görür; burada yalnızca
        Proje Yöneticisi/Finans/Saha rollerindeki kullanıcıların BU projeye erişimi yönetilir.
      </p>

      {users.length === 0 ? (
        <p className="text-text-muted">Bu projeye açıkça atanmış kullanıcı yok.</p>
      ) : (
        <ul className="flex flex-col gap-1.5">
          {users.map((u) => (
            <li
              key={u.user_id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border px-3 py-2"
            >
              <span className="flex items-center gap-2">
                <span className="font-medium">{u.full_name}</span>
                <span className="text-text-muted">{u.username}</span>
                {u.organization_role_name && <Badge tone="muted">{u.organization_role_name}</Badge>}
                {!u.user_is_active && <Badge tone="danger">Pasif</Badge>}
              </span>
              <span className="flex items-center gap-2">
                <Select
                  aria-label="Proje rolü"
                  value={u.project_role}
                  disabled={busy}
                  onChange={(e) => changeRole(u.user_id, e.target.value as ProjectRole)}
                  className="w-44"
                >
                  {(Object.keys(PROJECT_ROLE_LABELS) as ProjectRole[]).map((r) => (
                    <option key={r} value={r}>
                      {PROJECT_ROLE_LABELS[r]}
                    </option>
                  ))}
                </Select>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => remove(u)}
                  className="text-xs text-danger hover:underline"
                >
                  Erişimi Kaldır
                </button>
              </span>
            </li>
          ))}
        </ul>
      )}

      <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
        <Select
          required
          value={form.user_id}
          onChange={(e) => setForm({ ...form, user_id: e.target.value })}
          aria-label="Kullanıcı"
          className="w-56"
        >
          <option value="">Kullanıcı seçin</option>
          {available.map((u) => (
            <option key={u.id} value={u.id}>
              {u.full_name}
              {u.organization_role_code
                ? ` — ${ORG_ROLE_LABELS[u.organization_role_code as keyof typeof ORG_ROLE_LABELS] ?? u.organization_role_code}`
                : ""}
            </option>
          ))}
        </Select>
        <Select
          value={form.project_role}
          onChange={(e) => setForm({ ...form, project_role: e.target.value as ProjectRole })}
          aria-label="Proje rolü"
          className="w-44"
        >
          {(Object.keys(PROJECT_ROLE_LABELS) as ProjectRole[]).map((r) => (
            <option key={r} value={r}>
              {PROJECT_ROLE_LABELS[r]}
            </option>
          ))}
        </Select>
        <Button type="submit" loading={busy} disabled={!form.user_id}>
          Erişim Ver
        </Button>
      </form>
      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}
    </div>
  );
}

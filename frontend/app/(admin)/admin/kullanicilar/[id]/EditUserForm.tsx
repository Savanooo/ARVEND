"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import type { OrganizationRole, User, UserProjectAssignment } from "@/lib/types";
import { PROJECT_ROLE_LABELS } from "@/lib/types";

export function EditUserForm({
  user,
  roles,
  projects,
}: {
  user: User;
  roles: OrganizationRole[];
  projects: UserProjectAssignment[];
}) {
  const router = useRouter();

  const [fullName, setFullName] = useState(user.full_name);
  const [isActive, setIsActive] = useState(user.is_active ?? true);
  const [savingInfo, setSavingInfo] = useState(false);
  const [infoMsg, setInfoMsg] = useState<string | null>(null);

  // Yeni Rol seçicisi yalnızca roles listesindeki (atanabilir) kodlardan
  // biriyle başlatılır -- mevcut rol legacy_user gibi listede OLMAYAN bir
  // kodsa (yaygın: migration öncesi kullanıcılar) boş bırakılır, aksi
  // halde denetlenen &lt;select&gt; DOM'da bambaşka bir seçeneği (React'in
  // eşleşmeyen value için ilk seçeneği işaretlemesi) göstermiş olurdu --
  // "Mevcut rol" rozeti zaten gerçek değeri ayrıca gösterir.
  const [orgRoleCode, setOrgRoleCode] = useState(
    roles.some((r) => r.code === user.organization_role_code) ? (user.organization_role_code ?? "") : ""
  );
  const [savingOrgRole, setSavingOrgRole] = useState(false);
  const [orgRoleMsg, setOrgRoleMsg] = useState<string | null>(null);

  const [newPassword, setNewPassword] = useState("");
  const [savingPassword, setSavingPassword] = useState(false);
  const [passwordMsg, setPasswordMsg] = useState<string | null>(null);

  async function handleOrgRoleSubmit(e: FormEvent) {
    e.preventDefault();
    setSavingOrgRole(true);
    setOrgRoleMsg(null);
    try {
      await apiClient(`/api/v1/users/${user.id}/organization-role`, {
        method: "PUT",
        body: JSON.stringify({ role_code: orgRoleCode }),
      });
      setOrgRoleMsg("Kaydedildi.");
      router.refresh();
    } catch (err) {
      setOrgRoleMsg(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingOrgRole(false);
    }
  }

  async function handleInfoSubmit(e: FormEvent) {
    e.preventDefault();
    setSavingInfo(true);
    setInfoMsg(null);
    try {
      await apiClient(`/api/v1/users/${user.id}`, {
        method: "PUT",
        body: JSON.stringify({ full_name: fullName, is_active: isActive }),
      });
      setInfoMsg("Kaydedildi.");
      router.refresh();
    } catch (err) {
      setInfoMsg(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingInfo(false);
    }
  }

  async function handlePasswordSubmit(e: FormEvent) {
    e.preventDefault();
    setSavingPassword(true);
    setPasswordMsg(null);
    try {
      await apiClient(`/api/v1/users/${user.id}/password`, {
        method: "PATCH",
        body: JSON.stringify({ new_password: newPassword }),
      });
      setPasswordMsg("Şifre güncellendi.");
      setNewPassword("");
    } catch (err) {
      setPasswordMsg(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingPassword(false);
    }
  }

  return (
    <div className="flex max-w-md flex-col gap-6">
      <Card>
        <CardHeader>Kullanıcı Bilgileri</CardHeader>
        <CardBody>
          <form onSubmit={handleInfoSubmit} className="flex flex-col gap-4">
            <Input
              label="Ad Soyad"
              value={fullName}
              onChange={(e) => setFullName(e.target.value)}
              required
            />
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={isActive}
                onChange={(e) => setIsActive(e.target.checked)}
                className="accent-gold"
              />
              Aktif
            </label>
            {infoMsg && <p className="text-xs text-text-muted">{infoMsg}</p>}
            <Button type="submit" disabled={savingInfo}>
              {savingInfo ? "Kaydediliyor…" : "Kaydet"}
            </Button>
          </form>
        </CardBody>
      </Card>

      {/* Organizasyon Rolü — RBAC/Project Membership sprint'inin ince-taneli
          eksenidir, yukarıdaki "Rol" (admin/kullanici) alanından TAMAMEN
          AYRIDIR. roles listesi backend'de zaten legacy_user'ı ve
          super_admin'i HİÇ İÇERMEZ (bkz. ListOrganizationRoles(includeLegacy
          =false) ve organization_roles'ta super_admin satırının hiç
          bulunmaması) -- bu seçici o ikisini asla gösteremez. */}
      <Card>
        <CardHeader>Organizasyon Rolü</CardHeader>
        <CardBody>
          <form onSubmit={handleOrgRoleSubmit} className="flex flex-col gap-4">
            {/* Mevcut rol, "kullanici (eski sistem)" olabilir -- o kod
                SEÇİCİDE bilinçli olarak YOKTUR (yeni atama hedefi değil),
                bu yüzden değeri ayrı bir rozetle HER ZAMAN gösterilir;
                aksi halde seçici boş görünüp "hiç rolü yok" izlenimi
                verirdi. */}
            {user.organization_role_name && (
              <p className="text-xs text-text-muted">
                Mevcut rol: <Badge tone="muted">{user.organization_role_name}</Badge>
              </p>
            )}
            <Select
              label="Yeni Rol"
              value={orgRoleCode}
              onChange={(e) => setOrgRoleCode(e.target.value)}
              required
            >
              <option value="" disabled>
                Rol seçin
              </option>
              {roles.map((r) => (
                <option key={r.id} value={r.code}>
                  {r.name}
                </option>
              ))}
            </Select>
            <p className="text-xs text-text-muted">
              Sahip/Yönetici organizasyondaki tüm projeleri görür. Proje Yöneticisi/Finans/Saha
              yalnızca kendilerine atanan projelere erişir (bkz. proje detayındaki
              &quot;Proje Erişimi&quot; bölümü).
            </p>
            {orgRoleMsg && <p className="text-xs text-text-muted">{orgRoleMsg}</p>}
            <Button type="submit" disabled={savingOrgRole || !orgRoleCode}>
              {savingOrgRole ? "Kaydediliyor…" : "Kaydet"}
            </Button>
          </form>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Atandığı Projeler</CardHeader>
        <CardBody>
          {projects.length === 0 ? (
            <p className="text-sm text-text-muted">
              Bu kullanıcı açıkça hiçbir projeye atanmamış. (Sahip/Yönetici/eski kullanıcı
              rolündeyse zaten tüm projeleri koşulsuz görür.)
            </p>
          ) : (
            <ul className="flex flex-col gap-1.5 text-sm">
              {projects.map((p) => (
                <li key={p.project_id} className="flex items-center justify-between gap-2">
                  <Link href={`/projeler/${p.project_id}`} className="hover:text-gold hover:underline">
                    {p.project_no} — {p.project_name}
                  </Link>
                  <Badge tone="muted">{PROJECT_ROLE_LABELS[p.project_role]}</Badge>
                </li>
              ))}
            </ul>
          )}
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Şifre Sıfırla</CardHeader>
        <CardBody>
          <form onSubmit={handlePasswordSubmit} className="flex flex-col gap-4">
            <Input
              label="Yeni Şifre"
              type="password"
              minLength={8}
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              required
            />
            {passwordMsg && <p className="text-xs text-text-muted">{passwordMsg}</p>}
            <Button type="submit" variant="secondary" disabled={savingPassword}>
              {savingPassword ? "Kaydediliyor…" : "Şifreyi Sıfırla"}
            </Button>
          </form>
        </CardBody>
      </Card>
    </div>
  );
}

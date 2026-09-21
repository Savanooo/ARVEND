"use client";

import { MoreHorizontal, RotateCcw, Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { FormEvent, useMemo, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Drawer } from "@/components/ui/Drawer";
import { DropdownMenu, DropdownMenuItem } from "@/components/ui/DropdownMenu";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { Select } from "@/components/ui/Select";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Tabs } from "@/components/ui/Tabs";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import type { Organization, OrganizationRole, User } from "@/lib/types";

// Süper Admin'in firma kullanıcı yönetimi. "Kullanıcıyı Sil" DAHİL hiçbir
// işlem kullanıcı satırını fiziksel olarak KALDIRMAZ -- Sil bile bir
// YUMUŞAK silmedir (deleted_at + eşzamanlı pasifleştirme, bkz.
// backend/db/migrations/0043): erişimi kapatır, aktif/pasif listelerden
// kaybolur, Silinenler (Arşiv) görünümünde kalır ve Geri Yükle ile geri
// alınabilir. Görünen rol her zaman ORGANİZASYON rolüdür (Sahip/Yönetici/
// Proje Yöneticisi/Finans/Saha/özel). Son aktif Sahip koruması (hem
// pasifleştirme hem silme için) backend'de uygulanır; UI önceden
// devre dışı bırakıp tooltip'le açıklar.

type ModalState =
  | { kind: "provision"; presetRole?: string }
  | { kind: "role"; user: User }
  | { kind: "password"; user: User }
  | null;

type ViewFilter = "active" | "inactive" | "deleted";

export function UsersTab({
  organization,
  users,
  deletedUsers,
  roles,
  activeOwnerCount,
}: {
  organization: Organization;
  users: User[];
  deletedUsers: User[];
  roles: OrganizationRole[];
  activeOwnerCount: number;
}) {
  const router = useRouter();
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const [modal, setModal] = useState<ModalState>(null);
  const [busyUserId, setBusyUserId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<ViewFilter>("active");

  const base = `/api/v1/platform/organizations/${organization.id}/users`;

  const visibleUsers = useMemo(() => {
    if (filter === "deleted") return deletedUsers;
    if (filter === "inactive") return users.filter((u) => u.is_active === false);
    return users.filter((u) => u.is_active !== false);
  }, [filter, users, deletedUsers]);

  async function toggleActive(user: User) {
    setError(null);
    const deactivating = user.is_active !== false;
    const ok = await confirm({
      title: deactivating ? "Kullanıcıyı pasife al" : "Kullanıcıyı aktifleştir",
      message: deactivating
        ? `${user.full_name} (${user.username}) pasife alınacak: yeniden giriş yapamaz ve mevcut oturumu en geç birkaç dakika içinde (bir sonraki oturum yenilemesinde) sona erer. Kayıt silinmez, istendiğinde yeniden aktifleştirilebilir.`
        : `${user.full_name} (${user.username}) yeniden aktifleştirilecek ve giriş yapabilecek.`,
      confirmLabel: deactivating ? "Pasife Al" : "Aktifleştir",
      danger: deactivating,
    });
    if (!ok) return;
    setBusyUserId(user.id);
    try {
      await apiClient(`${base}/${user.id}/${deactivating ? "deactivate" : "reactivate"}`, { method: "POST" });
      toast.success(deactivating ? "Kullanıcı pasife alındı." : "Kullanıcı aktifleştirildi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusyUserId(null);
    }
  }

  async function deleteUser(user: User) {
    setError(null);
    const ok = await confirm({
      title: "Kullanıcı silinsin mi?",
      message: `${user.full_name} (${user.username}) silinecek: erişimi kaldırılır ve aktif kullanıcı listelerinden kaybolur. Geçmiş kayıtlar (denetim, atamalar) SİLİNMEZ; gerekirse Silinenler görünümünden geri yüklenebilir.`,
      confirmLabel: "Kullanıcıyı Sil",
      danger: true,
    });
    if (!ok) return;
    setBusyUserId(user.id);
    try {
      await apiClient(`${base}/${user.id}/delete`, { method: "POST" });
      toast.success("Kullanıcı silindi.");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusyUserId(null);
    }
  }

  async function restoreUser(user: User) {
    setError(null);
    setBusyUserId(user.id);
    try {
      await apiClient(`${base}/${user.id}/restore`, { method: "POST" });
      toast.success(`${user.full_name} geri yüklendi (Pasif olarak listeye döndü).`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusyUserId(null);
    }
  }

  return (
    <div className="flex flex-col gap-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-xs text-text-muted">
          {users.length} kullanıcı · {activeOwnerCount} aktif Sahip
        </p>
        <Button type="button" onClick={() => setModal({ kind: "provision" })}>
          + Kullanıcı Oluştur
        </Button>
      </div>

      {activeOwnerCount === 0 && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-danger/40 bg-danger/5 px-4 py-3 text-sm">
          <span>
            Bu firmanın <strong>aktif bir Sahibi yok</strong>. Firma ayarlarını ve kullanıcılarını yönetebilmesi için bir
            Sahip oluşturun ya da mevcut bir kullanıcıyı Sahip yapın.
          </span>
          <Button type="button" variant="secondary" onClick={() => setModal({ kind: "provision", presetRole: "owner" })}>
            Sahip Oluştur
          </Button>
        </div>
      )}

      <Tabs
        items={[
          { key: "active", label: "Aktif Kullanıcılar", active: filter === "active", onClick: () => setFilter("active") },
          { key: "inactive", label: "Pasif", active: filter === "inactive", onClick: () => setFilter("inactive") },
          {
            key: "deleted",
            label: `Silinenler${deletedUsers.length > 0 ? ` (${deletedUsers.length})` : ""}`,
            active: filter === "deleted",
            onClick: () => setFilter("deleted"),
          },
        ]}
      />

      {visibleUsers.length === 0 ? (
        <EmptyState
          title={
            filter === "deleted" ? "Silinmiş kullanıcı yok" : filter === "inactive" ? "Pasif kullanıcı yok" : "Henüz kullanıcı yok"
          }
          description={filter === "active" ? "Bu firma için ilk Sahibi oluşturun." : undefined}
        />
      ) : (
        <Table>
          <thead>
            <tr>
              <Th className="w-[26%]">Ad Soyad</Th>
              <Th className="w-[18%]">Kullanıcı Adı</Th>
              <Th className="w-[20%]">Rol</Th>
              <Th className="w-[12%]">Durum</Th>
              <Th className="w-[16%]">{filter === "deleted" ? "Silinme Tarihi" : "İlk Giriş / Şifre"}</Th>
              <Th className="w-[8%]" />
            </tr>
          </thead>
          <tbody>
            {visibleUsers.map((u) => {
              const isOwner = u.organization_role_code === "owner";
              const active = u.is_active !== false;
              const deleted = filter === "deleted";
              // Firmanın SON aktif Sahibi -- pasifleştirme/silme ve (rol
              // değişikliği modalındaki AYRI uyarıyla) rol düşürme backend'de
              // zaten reddedilir; burada eylemi baştan devre dışı bırakıp
              // NEDENİNİ bir tooltip'te açıklamak, kullanıcıyı bir 409
              // hatasıyla karşılaşmadan önce bilgilendirir.
              const isSoleActiveOwner = isOwner && active && activeOwnerCount <= 1;
              return (
                <Tr key={u.id}>
                  <Td className="font-medium">{u.full_name}</Td>
                  <Td>
                    <span className="rounded bg-surface-hover px-1.5 py-0.5 font-mono text-xs text-text-muted">
                      {u.username}
                    </span>
                  </Td>
                  <Td>
                    {isOwner ? (
                      <Badge tone="gold">Sahip</Badge>
                    ) : (
                      u.organization_role_name || <span className="text-danger">Rol atanmamış</span>
                    )}
                  </Td>
                  <Td>
                    {deleted ? (
                      <Badge tone="muted">Silindi</Badge>
                    ) : (
                      <Badge tone={active ? "success" : "danger"}>{active ? "Aktif" : "Pasif"}</Badge>
                    )}
                  </Td>
                  <Td>
                    {deleted ? (
                      <span className="text-text-muted">{u.deleted_at ? new Date(u.deleted_at).toLocaleString("tr-TR") : "—"}</span>
                    ) : u.must_change_password ? (
                      <Badge tone="info">Belirlenmeli</Badge>
                    ) : (
                      <span className="text-text-muted">Belirlendi</span>
                    )}
                  </Td>
                  <Td className="text-right">
                    {deleted ? (
                      <Button
                        type="button"
                        variant="secondary"
                        disabled={busyUserId === u.id}
                        onClick={() => restoreUser(u)}
                      >
                        <RotateCcw size={14} strokeWidth={1.75} />
                        Geri Yükle
                      </Button>
                    ) : (
                      <DropdownMenu
                        triggerLabel={`${u.full_name} için işlemler`}
                        trigger={<MoreHorizontal size={16} strokeWidth={1.75} />}
                      >
                        <DropdownMenuItem onClick={() => setModal({ kind: "role", user: u })}>Rolü Değiştir…</DropdownMenuItem>
                        <DropdownMenuItem onClick={() => setModal({ kind: "password", user: u })}>
                          İlk Şifreyi Yenile…
                        </DropdownMenuItem>
                        <DropdownMenuItem
                          disabled={busyUserId === u.id || isSoleActiveOwner}
                          title={isSoleActiveOwner ? "Firmanın son aktif Sahibi pasifleştirilemez." : undefined}
                          onClick={() => toggleActive(u)}
                        >
                          {active ? "Pasife Al" : "Aktifleştir"}
                        </DropdownMenuItem>
                        <div className="my-1 border-t border-border" />
                        <DropdownMenuItem
                          disabled={busyUserId === u.id || isSoleActiveOwner}
                          title={isSoleActiveOwner ? "Firmanın son aktif Sahibi silinemez." : undefined}
                          onClick={() => deleteUser(u)}
                          className={!isSoleActiveOwner ? "text-danger" : ""}
                        >
                          <Trash2 size={14} strokeWidth={1.75} />
                          Kullanıcıyı Sil
                        </DropdownMenuItem>
                      </DropdownMenu>
                    )}
                  </Td>
                </Tr>
              );
            })}
          </tbody>
        </Table>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}

      {modal?.kind === "provision" && (
        <ProvisionUserModal
          base={base}
          roles={roles}
          presetRole={modal.presetRole}
          onClose={() => setModal(null)}
          onDone={(message) => {
            setModal(null);
            toast.success(message);
            router.refresh();
          }}
        />
      )}
      {modal?.kind === "role" && (
        <ChangeRoleModal
          base={base}
          roles={roles}
          user={modal.user}
          onClose={() => setModal(null)}
          onDone={(message) => {
            setModal(null);
            toast.success(message);
            router.refresh();
          }}
        />
      )}
      {modal?.kind === "password" && (
        <ResetPasswordModal
          base={base}
          user={modal.user}
          onClose={() => setModal(null)}
          onDone={(message) => {
            setModal(null);
            toast.success(message);
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

function roleOptions(roles: OrganizationRole[]) {
  return roles.map((r) => (
    <option key={r.code} value={r.code}>
      {r.name}
    </option>
  ));
}

// assignableOrEmpty, bir kullanıcının MEVCUT organizasyon rolü atanabilir
// roller listesinde (legacy_user gibi migration artıkları hariç) yoksa
// boş döner -- aksi halde denetlenen &lt;select&gt; DOM'da value'suyla
// eşleşmeyen bir seçenek gösterir (tarayıcı ilk seçeneği işaretler),
// buton ise "değişmedi" sanıp devre dışı kalırdı.
function assignableOrEmpty(current: string | undefined, options: { code: string }[]): string {
  return current && options.some((o) => o.code === current) ? current : "";
}

function ProvisionUserModal({
  base,
  roles,
  presetRole,
  onClose,
  onDone,
}: {
  base: string;
  roles: OrganizationRole[];
  presetRole?: string;
  onClose: () => void;
  onDone: (message: string) => void;
}) {
  const [fullName, setFullName] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  // "Sahip Tanımla" banner düğmesi presetRole="owner" geçer (bilinçli
  // varsayılan); genel "+ Kullanıcı Tanımla" İSE bilinçli olarak BOŞ
  // başlar -- en yüksek yetkili role (Sahip) sessizce varsayılan
  // seçilirse, formu rol alanına hiç dokunmadan dolduran bir Süper Admin
  // istemeden fazladan bir Sahip oluşturabilir (ki bu ikinci Sahip ayrıca
  // gerçek Sahip üzerindeki son-Sahip korumasını da kaldırır).
  const [roleCode, setRoleCode] = useState(presetRole ?? "");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!roleCode) {
      setError("Organizasyon rolü seçin.");
      return;
    }
    if (username.trim().toLowerCase() === "admin") {
      setError("Genel 'admin' kullanıcı adı kullanılamaz; kişiye özel bir kullanıcı adı seçin.");
      return;
    }
    setLoading(true);
    try {
      const created = await apiClient<User>(base, {
        method: "POST",
        body: JSON.stringify({
          username: username.trim(),
          full_name: fullName.trim(),
          temporary_password: password,
          organization_role_code: roleCode,
        }),
      });
      onDone(`${created.full_name} oluşturuldu (${created.organization_role_name ?? roleCode}). İlk girişte şifresini değiştirmesi istenecek.`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <Drawer
      open
      onClose={onClose}
      title={presetRole === "owner" ? "Sahip Oluştur" : "Yeni Kullanıcı Oluştur"}
      footer={
        <>
          <Button type="button" variant="ghost" onClick={onClose}>
            Vazgeç
          </Button>
          <Button type="submit" form="provision-user-form" disabled={loading || !roleCode}>
            {loading ? "Oluşturuluyor…" : "Kullanıcı Oluştur"}
          </Button>
        </>
      }
    >
      <form id="provision-user-form" onSubmit={handleSubmit} className="flex flex-col gap-6">
        <section className="flex flex-col gap-4">
          <p className="text-xs font-semibold uppercase tracking-widest text-text-muted">Kimlik</p>
          <Input label="Ad Soyad" required value={fullName} onChange={(e) => setFullName(e.target.value)} />
          <div className="flex flex-col gap-1.5">
            <Input
              label="Kullanıcı Adı"
              required
              autoComplete="off"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
            />
            <p className="text-xs text-text-muted">Giriş için kullanılır; kişiye özel olmalı, sonradan değiştirilemez.</p>
          </div>
        </section>

        <section className="flex flex-col gap-4 border-t border-border pt-5">
          <p className="text-xs font-semibold uppercase tracking-widest text-text-muted">Yetki</p>
          <div className="flex flex-col gap-1.5">
            <Select label="Organizasyon Rolü" value={roleCode} onChange={(e) => setRoleCode(e.target.value)} required>
              <option value="" disabled>
                Rol seçin
              </option>
              {roleOptions(roles)}
            </Select>
            <p className="text-xs text-text-muted">
              Sahip/Yönetici tüm projeleri koşulsuz görür. Proje Yöneticisi/Finans/Saha yalnızca atandıkları projelere
              erişir.
            </p>
          </div>
        </section>

        <section className="flex flex-col gap-4 border-t border-border pt-5">
          <p className="text-xs font-semibold uppercase tracking-widest text-text-muted">Geçici Şifre</p>
          <Input
            label="Geçici Şifre"
            type="password"
            required
            minLength={8}
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <p className="text-xs text-text-muted">
            Kullanıcı ilk girişte bu şifreyi değiştirmek zorunda kalır. Şifreyi kendisine güvenli bir kanaldan iletmeniz
            gerekir -- sistem otomatik e-posta göndermez.
          </p>
        </section>

        {error && <p className="text-xs text-danger">{error}</p>}
      </form>
    </Drawer>
  );
}

function ChangeRoleModal({
  base,
  roles,
  user,
  onClose,
  onDone,
}: {
  base: string;
  roles: OrganizationRole[];
  user: User;
  onClose: () => void;
  onDone: (message: string) => void;
}) {
  // Mevcut rol atanabilir listede yoksa (ör. legacy_user -- yeni atama
  // hedefi değil, bu yüzden GET .../roles onu hiç döndürmez) boş başlar;
  // aksi halde denetlenen &lt;select&gt; state'iyle eşleşmeyen bir DOM
  // seçimi gösterir ve "Kaydet" hep devre dışı kalır (bkz. UsersTab.tsx
  // yorumu, Plan seçicisindeki AYNI desen).
  const [roleCode, setRoleCode] = useState(assignableOrEmpty(user.organization_role_code, roles));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await apiClient<{ organization_role_code: string; organization_role_name: string }>(
        `${base}/${user.id}/organization-role`,
        { method: "PUT", body: JSON.stringify({ role_code: roleCode }) }
      );
      onDone(`${user.full_name} artık ${res.organization_role_name}.`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <Modal open onClose={onClose} title={`Rolü Değiştir: ${user.full_name}`}>
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        {user.organization_role_name && (
          <p className="text-xs text-text-muted">
            Mevcut rol: <Badge tone="muted">{user.organization_role_name}</Badge>
          </p>
        )}
        <Select label="Yeni Rol" value={roleCode} onChange={(e) => setRoleCode(e.target.value)} required>
          <option value="" disabled>
            Rol seçin
          </option>
          {roleOptions(roles)}
        </Select>
        {user.organization_role_code === "owner" && roleCode !== "owner" && roleCode !== "" && (
          <p className="text-xs text-text-muted">
            Bir Sahibi başka role düşürmek için firmada en az bir başka aktif Sahip bulunmalıdır; aksi halde işlem
            reddedilir.
          </p>
        )}
        {error && <p className="text-xs text-danger">{error}</p>}
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Vazgeç
          </Button>
          <Button type="submit" disabled={loading || !roleCode || roleCode === user.organization_role_code}>
            {loading ? "Kaydediliyor…" : "Kaydet"}
          </Button>
        </div>
      </form>
    </Modal>
  );
}

function ResetPasswordModal({
  base,
  user,
  onClose,
  onDone,
}: {
  base: string;
  user: User;
  onClose: () => void;
  onDone: (message: string) => void;
}) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await apiClient(`${base}/${user.id}/reset-initial-password`, {
        method: "POST",
        body: JSON.stringify({ temporary_password: password }),
      });
      onDone(`${user.full_name} için ilk şifre yenilendi; ilk girişte değiştirmesi istenecek.`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <Modal open onClose={onClose} title={`İlk Şifreyi Yenile: ${user.full_name}`}>
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        <p className="text-xs text-text-muted">
          Mevcut şifre geçersiz olur, kullanıcının mevcut oturumu en geç birkaç dakika içinde (bir sonraki oturum
          yenilemesinde) sona erer ve ilk girişte yeni bir şifre belirlemesi istenir. Geçici şifreyi güvenli bir
          kanaldan iletin.
        </p>
        <Input
          label="Geçici Şifre"
          type="password"
          required
          minLength={8}
          autoComplete="new-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        {error && <p className="text-xs text-danger">{error}</p>}
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Vazgeç
          </Button>
          <Button type="submit" variant="danger" disabled={loading}>
            {loading ? "Yenileniyor…" : "İlk Şifreyi Yenile"}
          </Button>
        </div>
      </form>
    </Modal>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { PermissionMatrix, type AccessState } from "@/components/permissions/PermissionMatrix";
import { rolesWithCurrent, saveUserAccess } from "@/components/permissions/saveUserAccess";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import type { Employee, OrganizationRole, Permission, User, UserPermissions } from "@/lib/types";

type LoginMode = "none" | "existing" | "new";

const EMPTY_ACCESS: AccessState = { roleCode: "", selected: new Set() };

// Yeni personel + (isteğe bağlı) sisteme giriş hesabı + rol + kişiye özel
// yetkiler tek formda. Kaydetme sırası: (yeni hesap) -> personel -> yetkiler.
// Personel kaydı hesaptan sonra başarısız olursa hesap "mevcut hesaba bağla"
// olarak seçili kalır, tekrar denemek ikinci bir hesap oluşturmaz.
export function NewEmployeeForm({
  users,
  roles,
  catalog,
  canLinkUsers,
  canReadAccess,
  canEditAccess,
  canCreateLogin,
}: {
  users: User[];
  roles: OrganizationRole[];
  catalog: Permission[];
  canLinkUsers: boolean;
  canReadAccess: boolean;
  canEditAccess: boolean;
  canCreateLogin: boolean;
}) {
  const router = useRouter();
  const [form, setForm] = useState({
    full_name: "",
    phone: "",
    position: "",
    daily_wage: "",
    salary: "",
    start_date: "",
    description: "",
  });
  const [mode, setMode] = useState<LoginMode>("none");
  const [knownUsers, setKnownUsers] = useState<User[]>(users);
  const [existingUserId, setExistingUserId] = useState("");
  const [savedRole, setSavedRole] = useState("");
  const [existingDetail, setExistingDetail] = useState<UserPermissions | null>(null);
  const [loadingAccess, setLoadingAccess] = useState(false);
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [access, setAccess] = useState<AccessState>(EMPTY_ACCESS);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  function changeMode(next: LoginMode) {
    setMode(next);
    setExistingUserId("");
    setSavedRole("");
    setExistingDetail(null);
    setAccess(EMPTY_ACCESS);
  }

  async function selectExisting(userId: string) {
    setExistingUserId(userId);
    setAccess(EMPTY_ACCESS);
    setSavedRole("");
    setExistingDetail(null);
    if (!userId || !canReadAccess) return;
    setLoadingAccess(true);
    try {
      const detail = await apiClient<UserPermissions>(`/api/v1/users/${userId}/permissions`);
      setAccess({ roleCode: detail.role_code, selected: new Set(detail.permissions) });
      setSavedRole(detail.role_code);
      setExistingDetail(detail);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoadingAccess(false);
    }
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (mode === "new" && !access.roleCode) {
      setError("Giriş hesabı için bir rol seçin.");
      return;
    }
    if (mode === "existing" && !existingUserId) {
      setError("Bağlanacak giriş hesabını seçin.");
      return;
    }
    setLoading(true);

    let userId = mode === "existing" ? existingUserId : "";
    let roleBaseline = savedRole;
    if (mode === "new") {
      try {
        const created = await apiClient<User>("/api/v1/users", {
          method: "POST",
          body: JSON.stringify({
            username: username.trim(),
            password,
            full_name: form.full_name.trim(),
            organization_role_code: access.roleCode,
          }),
        });
        userId = created.id;
        roleBaseline = access.roleCode;
        // Personel adımı başarısız olursa tekrar denemede hesap yeniden
        // oluşturulmasın: formu "mevcut hesaba bağla"ya çevir.
        setKnownUsers((prev) => [...prev, created]);
        setMode("existing");
        setExistingUserId(created.id);
        setSavedRole(access.roleCode);
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
        setLoading(false);
        return;
      }
    }

    let employee: Employee;
    try {
      employee = await apiClient<Employee>("/api/v1/employees", {
        method: "POST",
        body: JSON.stringify({
          full_name: form.full_name,
          phone: form.phone,
          position: form.position,
          daily_wage: form.daily_wage ? parseFloat(form.daily_wage) : null,
          salary: form.salary ? parseFloat(form.salary) : null,
          start_date: form.start_date || null,
          description: form.description,
          user_id: userId,
        }),
      });
    } catch (err) {
      const reason = err instanceof ApiError ? err.message : "Bağlantı hatası";
      setError(
        mode === "new"
          ? `Giriş hesabı oluşturuldu ama personel kaydedilemedi: ${reason}. Tekrar kaydedebilirsin; hesap yeniden oluşturulmaz.`
          : reason
      );
      setLoading(false);
      return;
    }

    if (userId && canEditAccess && access.roleCode) {
      try {
        await saveUserAccess(userId, roleBaseline, access);
      } catch {
        router.push(`/admin/personel/${employee.id}?uyari=yetki`);
        return;
      }
    }
    router.push("/admin/personel");
    router.refresh();
  }

  const showMatrix = mode === "new" || (mode === "existing" && Boolean(existingUserId) && canReadAccess && !loadingAccess);

  return (
    <form onSubmit={handleSubmit} className="grid grid-cols-1 items-start gap-6 xl:grid-cols-[minmax(0,28rem)_minmax(0,1fr)]">
      <Card>
        <CardHeader>Personel Bilgileri</CardHeader>
        <CardBody>
          <div className="flex flex-col gap-4">
            <Input
              label="Ad Soyad"
              required
              value={form.full_name}
              onChange={(e) => setForm({ ...form, full_name: e.target.value })}
            />
            <div className="grid grid-cols-2 gap-3">
              <Input label="Telefon" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
              <Input label="Görev" value={form.position} onChange={(e) => setForm({ ...form, position: e.target.value })} />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Günlük Yevmiye"
                type="number"
                step="0.01"
                min={0}
                value={form.daily_wage}
                onChange={(e) => setForm({ ...form, daily_wage: e.target.value })}
              />
              <Input
                label="Aylık Maaş"
                type="number"
                step="0.01"
                min={0}
                value={form.salary}
                onChange={(e) => setForm({ ...form, salary: e.target.value })}
              />
            </div>
            <Input
              label="İşe Başlama Tarihi"
              type="date"
              value={form.start_date}
              onChange={(e) => setForm({ ...form, start_date: e.target.value })}
            />
            <Input
              label="Açıklama"
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
            />
          </div>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Sisteme Giriş ve Yetkiler</CardHeader>
        <CardBody>
          <div className="flex flex-col gap-4">
            <div className="flex flex-wrap gap-4 text-sm">
              <label className="flex items-center gap-2">
                <input type="radio" checked={mode === "none"} onChange={() => changeMode("none")} className="accent-gold" />
                Giriş hesabı yok
              </label>
              {canLinkUsers && (
                <label className="flex items-center gap-2">
                  <input
                    type="radio"
                    checked={mode === "existing"}
                    onChange={() => changeMode("existing")}
                    className="accent-gold"
                  />
                  Mevcut hesaba bağla
                </label>
              )}
              {canCreateLogin && (
                <label className="flex items-center gap-2">
                  <input type="radio" checked={mode === "new"} onChange={() => changeMode("new")} className="accent-gold" />
                  Yeni giriş hesabı aç
                </label>
              )}
            </div>

            {mode === "none" && (
              <p className="text-sm text-text-muted">
                Bu personel yalnızca puantaj/maaş kaydı olarak tutulur, sisteme giriş yapamaz. İstersen sonradan personel
                düzenleme ekranından hesap açabilirsin.
              </p>
            )}

            {mode === "existing" && (
              <Select
                label="Giriş Hesabı"
                value={existingUserId}
                onChange={(e) => selectExisting(e.target.value)}
                required
              >
                <option value="">Hesap seçin</option>
                {knownUsers.map((u) => (
                  <option key={u.id} value={u.id}>
                    {u.full_name} ({u.username})
                  </option>
                ))}
              </Select>
            )}

            {mode === "new" && (
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <Input
                  label="Kullanıcı Adı"
                  required
                  autoComplete="off"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                />
                <Input
                  label="Şifre"
                  type="password"
                  required
                  minLength={8}
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
              </div>
            )}

            {loadingAccess && <p className="text-sm text-text-muted">Hesabın yetkileri yükleniyor…</p>}
            {showMatrix && (
              <PermissionMatrix
                roles={mode === "existing" ? rolesWithCurrent(roles, existingDetail) : roles}
                catalog={catalog}
                value={access}
                onChange={setAccess}
                disabled={!canEditAccess}
              />
            )}
          </div>
        </CardBody>
      </Card>

      <div className="flex items-center gap-3 xl:col-span-2">
        <Button type="submit" loading={loading}>
          Personel Ekle
        </Button>
        {error && <p className="text-xs text-danger">{error}</p>}
      </div>
    </form>
  );
}

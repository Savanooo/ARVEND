"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { useToast } from "@/components/ui/Toast";
import { LABEL } from "@/components/ui/styles";
import { apiClient, ApiError } from "@/lib/api";
import {
  NEW_EMPLOYEE_CHOICE,
  employeeOptionLabel,
  personnelDecision,
  personnelHelper,
} from "@/lib/person-link";
import type { CreatedUser, Employee, OrganizationRole } from "@/lib/types";

// "Personel kaydı" seçicisinde "yeni kayıt" seçeneğinin <option> değeri
// (NEW_EMPLOYEE_CHOICE boş dize; boş değer "Hangi kayıt?" yer tutucusunun).
const NEW_OPTION = "__yeni";

// Organizasyon rolü BURADA seçilir (Süper Admin'in ProvisionUserModal'ıyla
// AYNI desen) -- eskiden bu form yalnızca kaba bir "Rol" (Kullanıcı/
// Yönetici) alır, organizasyon rolünü HİÇ sormazdı; backend de bunu
// sessizce "legacy_user"a (migration-only, atama HEDEFİ olmayan bir rol)
// düşürüyordu -- Kullanıcılar listesinde "(Eski Sistem)" rozetiyle görünen
// gerçek bir üretim hatasıydı. Bilinçli olarak BOŞ başlar (bkz. Süper
// Admin'in AYNI gerekçesi): en yüksek yetkili rol sessizce varsayılan
// seçilirse, formu rol alanına dokunmadan dolduran bir Sahip/Yönetici
// istemeden fazladan bir Sahip oluşturabilir.
//
// Kişi = tek kayıt (mobil "Yeni Kullanıcı" ile aynı): hesap açılırken kişi
// Personel'e de eklenir (varsayılan açık) ya da mevcut bir personel
// kaydına bağlanır. Aynı adlı bağlantısız personel varsa önceden seçili
// gelir; karar lib/person-link.ts personnelDecision'da.
export function NewUserForm({
  roles,
  canManageEmployees,
  unlinkedEmployees,
  employeesError,
}: {
  roles: OrganizationRole[];
  // "Personeli düzenleme": personel bölümü yalnızca bununla görünür.
  canManageEmployees: boolean;
  // Bağlanabilecek (aktif, hesapsız) personel; null = bilinmiyor (görme
  // izni yok ya da alınamadı) -- backend varsayılanı uygulanır.
  unlinkedEmployees: Employee[] | null;
  employeesError: boolean;
}) {
  const router = useRouter();
  const toast = useToast();
  const [fullName, setFullName] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [roleCode, setRoleCode] = useState("");
  const [createEmployee, setCreateEmployee] = useState(true);
  // Yöneticinin seçimi: null = dokunulmadı (ada göre varsayılan).
  const [employeeChoice, setEmployeeChoice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const personnel = personnelDecision({
    canManage: canManageEmployees,
    createEmployee,
    unlinked: unlinkedEmployees,
    fullName,
    choice: employeeChoice,
  });
  const helper = personnelHelper(personnel);
  const sameNameMatch =
    personnel.matches.length === 1 && personnel.selected === personnel.matches[0].id ? personnel.matches[0] : null;

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!roleCode) {
      setError("Organizasyon rolü seçin.");
      return;
    }
    if (canManageEmployees && createEmployee && unlinkedEmployees && personnel.selected === null) {
      setError("Aynı adlı birden çok personel var; hangisi olduğunu seç ya da yeni kayıt aç.");
      return;
    }
    setLoading(true);
    try {
      const created = await apiClient<CreatedUser>("/api/v1/users", {
        method: "POST",
        body: JSON.stringify({
          username: username.trim(),
          password,
          full_name: fullName.trim(),
          organization_role_code: roleCode,
          ...personnel.body,
        }),
      });
      // Sunucunun personel adımı özeti ("Personel kaydı da oluşturuldu." ...).
      const note = created.employee_link?.message ?? "";
      toast.success(note ? `Kullanıcı oluşturuldu. ${note}` : "Kullanıcı oluşturuldu.");
      router.push("/admin/kullanicilar");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <Card className="max-w-md">
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input label="Ad Soyad" required value={fullName} onChange={(e) => setFullName(e.target.value)} />
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
          <div className="flex flex-col gap-1.5">
            <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
              Organizasyon Rolü
            </label>
            <select
              value={roleCode}
              onChange={(e) => setRoleCode(e.target.value)}
              required
              className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
            >
              <option value="" disabled>
                Rol seçin
              </option>
              {roles.map((r) => (
                <option key={r.code} value={r.code}>
                  {r.name}
                </option>
              ))}
            </select>
            <p className="text-xs text-text-muted">
              Sahip/Yönetici tüm projeleri koşulsuz görür. Proje Yöneticisi/Finans/Saha yalnızca atandıkları
              projelere erişir.
            </p>
          </div>

          {canManageEmployees && (
            <div className="flex flex-col gap-3 border-t border-border pt-4">
              <p className={LABEL}>Personel Kaydı</p>
              <label className="flex items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={createEmployee}
                  disabled={loading}
                  onChange={(e) => {
                    setCreateEmployee(e.target.checked);
                    setError(null);
                  }}
                  className="mt-0.5 accent-gold"
                />
                <span>
                  Personel kaydı da oluştur
                  <span className="block text-xs text-text-muted">
                    Kişi görev atanabilsin, mesai ve maaş listelerinde görünsün diye Personel&apos;e de eklenir.
                  </span>
                </span>
              </label>

              {createEmployee && unlinkedEmployees && (
                <div className="flex flex-col gap-1.5">
                  <Select
                    id="employee_choice"
                    label="Personel kaydı"
                    value={
                      personnel.selected === null
                        ? ""
                        : personnel.selected === NEW_EMPLOYEE_CHOICE
                          ? NEW_OPTION
                          : personnel.selected
                    }
                    disabled={loading}
                    onChange={(e) => {
                      setEmployeeChoice(e.target.value === NEW_OPTION ? NEW_EMPLOYEE_CHOICE : e.target.value);
                      setError(null);
                    }}
                  >
                    {personnel.selected === null && (
                      <option value="" disabled>
                        Hangi kayıt?
                      </option>
                    )}
                    <option value={NEW_OPTION}>Yeni personel kaydı oluştur</option>
                    {personnel.ordered.map((emp) => (
                      <option key={emp.id} value={emp.id}>
                        {employeeOptionLabel(emp)}
                      </option>
                    ))}
                  </Select>
                  {helper && <p className="text-xs text-text-muted">{helper}</p>}
                  {personnel.selected === null && (
                    <p className="text-xs text-text-muted">
                      Aynı adlı birden çok personel kaydı var; hangisi olduğunu seç ya da yeni kayıt aç.
                    </p>
                  )}
                </div>
              )}

              {createEmployee && !unlinkedEmployees && (
                <p
                  className={
                    employeesError
                      ? "rounded-md border border-gold/40 bg-gold-soft px-3 py-2 text-xs"
                      : "text-xs text-text-muted"
                  }
                >
                  {employeesError
                    ? "Personel listesi alınamadı. Kayıt yine de açılır: aynı adlı tek bağlantısız personel varsa hesap ona bağlanır, yoksa yeni personel kaydı oluşturulur."
                    : "Aynı adlı tek bağlantısız personel varsa hesap ona bağlanır; yoksa yeni personel kaydı oluşturulur."}
                </p>
              )}

              {createEmployee && sameNameMatch && (
                <p className="rounded-md border border-success/30 bg-success-soft px-3 py-2 text-xs text-success">
                  &quot;{sameNameMatch.full_name}&quot; personel kaydı bu hesaba bağlanacak.
                </p>
              )}
            </div>
          )}

          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading || !roleCode}>
            {loading ? "Kaydediliyor…" : "Kullanıcı Oluştur"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}

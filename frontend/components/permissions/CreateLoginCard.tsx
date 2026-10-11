"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { employeeUpdateBody } from "@/lib/person-link";
import type { CreatedUser, Employee, OrganizationRole, Permission } from "@/lib/types";

import { PermissionMatrix, type AccessState } from "./PermissionMatrix";
import { saveUserAccess } from "./saveUserAccess";

// Giriş hesabı olmayan bir personele, personel ekranından hesap açar:
// kullanıcı adı + şifre + rol + kişiye özel yetkiler tek formda.
export function CreateLoginCard({
  employee,
  roles,
  catalog,
}: {
  employee: Employee;
  roles: OrganizationRole[];
  catalog: Permission[];
}) {
  const router = useRouter();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [access, setAccess] = useState<AccessState>({ roleCode: "", selected: new Set() });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!access.roleCode) {
      setError("Bir rol seçin.");
      return;
    }
    setBusy(true);
    let created: CreatedUser;
    try {
      // Hesap BU personele, hesapla aynı işlemde bağlanır (employee_id): sunucu
      // kendi kuralıyla yeni bir personel açmaz ya da aynı adlı başka bir
      // kayda bağlamaz (bkz. mobile/API_CONTRACT.md "Person = one record").
      created = await apiClient<CreatedUser>("/api/v1/users", {
        method: "POST",
        body: JSON.stringify({
          username: username.trim(),
          password,
          full_name: employee.full_name,
          organization_role_code: access.roleCode,
          employee_id: employee.id,
        }),
      });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setBusy(false);
      return;
    }

    try {
      // Sunucu bağı onayladıysa ikinci istek gerekmez. Onaylamadıysa (eski
      // sunucu) eski yol: kayıt employees.manage ile okundu -> ücretler dolu
      // gelir ve aynen geri yazılır (PUT tam-güncellemedir).
      if (created.employee_id !== employee.id) {
        await apiClient(`/api/v1/employees/${employee.id}`, {
          method: "PUT",
          body: JSON.stringify(employeeUpdateBody(employee, created.id)),
        });
      }
    } catch (err) {
      setError(
        `"${created.username}" giriş hesabı oluşturuldu ama bu personele bağlanamadı (${
          err instanceof ApiError ? err.message : "bağlantı hatası"
        }). Üstteki "Bağlı Kullanıcı Hesabı" alanından bağlayabilirsin.`
      );
      setBusy(false);
      router.refresh();
      return;
    }

    try {
      // Rol hesap oluşturulurken zaten verildi; yalnızca kişiye özel farklar yazılır.
      await saveUserAccess(created.id, access.roleCode, access);
    } catch (err) {
      setError(
        `Giriş hesabı oluşturuldu ve bağlandı, ama kişiye özel yetkiler kaydedilemedi (${
          err instanceof ApiError ? err.message : "bağlantı hatası"
        }). Yetkileri aşağıdan tekrar kaydedebilirsin.`
      );
    }
    setBusy(false);
    router.refresh();
  }

  return (
    <Card>
      <CardHeader>Sisteme Giriş ve Yetkiler</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <p className="text-sm text-text-muted">
            Bu personelin sisteme giriş hesabı yok. Aşağıdan bir hesap açıp rolünü ve yetkilerini tek tek ayarlayabilirsin.
          </p>
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
          <PermissionMatrix roles={roles} catalog={catalog} value={access} onChange={setAccess} />
          {error && <p className="text-xs text-danger">{error}</p>}
          <div>
            <Button type="submit" loading={busy} disabled={!access.roleCode}>
              Giriş Hesabı Oluştur
            </Button>
          </div>
        </form>
      </CardBody>
    </Card>
  );
}

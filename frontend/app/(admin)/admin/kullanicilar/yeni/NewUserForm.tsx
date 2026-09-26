"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { OrganizationRole, User } from "@/lib/types";

// Organizasyon rolü BURADA seçilir (Süper Admin'in ProvisionUserModal'ıyla
// AYNI desen) -- eskiden bu form yalnızca kaba bir "Rol" (Kullanıcı/
// Yönetici) alır, organizasyon rolünü HİÇ sormazdı; backend de bunu
// sessizce "legacy_user"a (migration-only, atama HEDEFİ olmayan bir rol)
// düşürüyordu -- Kullanıcılar listesinde "(Eski Sistem)" rozetiyle görünen
// gerçek bir üretim hatasıydı. Bilinçli olarak BOŞ başlar (bkz. Süper
// Admin'in AYNI gerekçesi): en yüksek yetkili rol sessizce varsayılan
// seçilirse, formu rol alanına dokunmadan dolduran bir Sahip/Yönetici
// istemeden fazladan bir Sahip oluşturabilir.
export function NewUserForm({ roles }: { roles: OrganizationRole[] }) {
  const router = useRouter();
  const [fullName, setFullName] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [roleCode, setRoleCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!roleCode) {
      setError("Organizasyon rolü seçin.");
      return;
    }
    setLoading(true);
    try {
      await apiClient<User>("/api/v1/users", {
        method: "POST",
        body: JSON.stringify({
          username: username.trim(),
          password,
          full_name: fullName.trim(),
          organization_role_code: roleCode,
        }),
      });
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
          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading || !roleCode}>
            {loading ? "Kaydediliyor…" : "Kullanıcı Oluştur"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}

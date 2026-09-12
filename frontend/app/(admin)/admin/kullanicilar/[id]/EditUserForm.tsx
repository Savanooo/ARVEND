"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Role, User } from "@/lib/types";

export function EditUserForm({ user }: { user: User }) {
  const router = useRouter();

  const [fullName, setFullName] = useState(user.full_name);
  const [role, setRole] = useState<Role>(user.role);
  const [isActive, setIsActive] = useState(user.is_active ?? true);
  const [savingInfo, setSavingInfo] = useState(false);
  const [infoMsg, setInfoMsg] = useState<string | null>(null);

  const [newPassword, setNewPassword] = useState("");
  const [savingPassword, setSavingPassword] = useState(false);
  const [passwordMsg, setPasswordMsg] = useState<string | null>(null);

  async function handleInfoSubmit(e: FormEvent) {
    e.preventDefault();
    setSavingInfo(true);
    setInfoMsg(null);
    try {
      await apiClient(`/api/v1/users/${user.id}`, {
        method: "PUT",
        body: JSON.stringify({ full_name: fullName, role, is_active: isActive }),
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
            <div className="flex flex-col gap-1.5">
              <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
                Rol
              </label>
              <select
                value={role}
                onChange={(e) => setRole(e.target.value as Role)}
                className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
              >
                <option value="kullanici">Kullanıcı</option>
                <option value="admin">Yönetici</option>
              </select>
            </div>
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

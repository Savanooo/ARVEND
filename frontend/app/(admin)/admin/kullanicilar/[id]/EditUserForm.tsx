"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { User, UserProjectAssignment } from "@/lib/types";
import { PROJECT_ROLE_LABELS } from "@/lib/types";

// Rol ve kişiye özel yetkiler bu formda DEĞİL, yanındaki UserAccessCard'da
// (Personel ekranıyla ortak bileşen).
export function EditUserForm({
  user,
  projects,
  canManage,
}: {
  user: User;
  projects: UserProjectAssignment[];
  canManage: boolean;
}) {
  const router = useRouter();

  const [fullName, setFullName] = useState(user.full_name);
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
      // Backend sıfırlanan şifreyi geçici sayar (ilk girişte kullanıcı kendi
      // şifresini belirler) ve açık oturumlarını kapatır.
      setPasswordMsg("Şifre sıfırlandı. Açık oturumları kapatıldı; ilk girişte kendi şifresini belirleyecek.");
      setNewPassword("");
    } catch (err) {
      setPasswordMsg(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingPassword(false);
    }
  }

  return (
    <div className="flex flex-col gap-6">
      <Card>
        <CardHeader>Kullanıcı Bilgileri</CardHeader>
        <CardBody>
          <form onSubmit={handleInfoSubmit} className="flex flex-col gap-4">
            <Input
              label="Ad Soyad"
              value={fullName}
              disabled={!canManage}
              onChange={(e) => setFullName(e.target.value)}
              required
            />
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={isActive}
                disabled={!canManage}
                onChange={(e) => setIsActive(e.target.checked)}
                className="accent-gold"
              />
              Aktif
            </label>
            {infoMsg && <p className="text-xs text-text-muted">{infoMsg}</p>}
            {canManage && (
              <Button type="submit" disabled={savingInfo}>
                {savingInfo ? "Kaydediliyor…" : "Kaydet"}
              </Button>
            )}
          </form>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Atandığı Projeler</CardHeader>
        <CardBody>
          {projects.length === 0 ? (
            <p className="text-sm text-text-muted">
              Bu kullanıcı açıkça hiçbir projeye atanmamış. (Sahip/Yönetici/eski kullanıcı rolündeyse zaten tüm projeleri
              koşulsuz görür.)
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

      {canManage && (
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
      )}
    </div>
  );
}

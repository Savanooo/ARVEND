"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { ApiError } from "@/lib/api";
import type { OrganizationRole, Permission, UserPermissions } from "@/lib/types";

import { PermissionMatrix, type AccessState } from "./PermissionMatrix";
import { rolesWithCurrent, sameSet, saveUserAccess } from "./saveUserAccess";

// Var olan bir giriş hesabının rolü + kişiye özel detaylı yetkileri
// (Personel düzenleme ve Kullanıcı düzenleme ekranlarında ortak).
export function UserAccessCard({
  userId,
  username,
  initial,
  roles,
  catalog,
  canEdit,
}: {
  userId: string;
  username?: string;
  initial: UserPermissions;
  roles: OrganizationRole[];
  catalog: Permission[];
  canEdit: boolean;
}) {
  const router = useRouter();
  const [saved, setSaved] = useState<AccessState>({ roleCode: initial.role_code, selected: new Set(initial.permissions) });
  const [value, setValue] = useState<AccessState>(saved);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const dirty = value.roleCode !== saved.roleCode || !sameSet(value.selected, saved.selected);

  async function save() {
    setBusy(true);
    setMessage(null);
    try {
      await saveUserAccess(userId, saved.roleCode, value);
      setSaved(value);
      setMessage({ ok: true, text: "Rol ve yetkiler kaydedildi." });
      router.refresh();
    } catch (err) {
      setMessage({ ok: false, text: err instanceof ApiError ? err.message : "Bağlantı hatası" });
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between gap-2">
          <span>Rol ve Yetkiler</span>
          {username && <span className="text-xs font-normal normal-case text-text-muted">Giriş hesabı: {username}</span>}
        </div>
      </CardHeader>
      <CardBody>
        <div className="flex flex-col gap-4">
          {!canEdit && (
            <p className="text-xs text-text-muted">
              Yetkileri yalnızca görüntüleyebilirsin; değiştirmek için rolünde &quot;Rolleri ve izinlerini
              düzenleme&quot; izni olmalı.
            </p>
          )}
          <PermissionMatrix
            roles={rolesWithCurrent(roles, initial)}
            catalog={catalog}
            value={value}
            onChange={setValue}
            disabled={!canEdit}
          />
          {canEdit && (
            <div className="flex items-center gap-3 border-t border-border pt-4">
              <Button type="button" onClick={save} loading={busy} disabled={!dirty || !value.roleCode}>
                Rol ve Yetkileri Kaydet
              </Button>
              {dirty && (
                <button type="button" onClick={() => setValue(saved)} className="text-xs text-text-muted hover:underline">
                  Değişiklikleri geri al
                </button>
              )}
              {message && <p className={`text-xs ${message.ok ? "text-success" : "text-danger"}`}>{message.text}</p>}
            </div>
          )}
        </div>
      </CardBody>
    </Card>
  );
}

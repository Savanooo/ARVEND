"use client";

import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { apiClient, ApiError } from "@/lib/api";
import type { OrganizationRole, Permission } from "@/lib/types";

// Roller & Yetkiler — RBAC/Project Membership sprint'i. Bu sprintte
// organizasyonlar YENİ bir özel rol OLUŞTURAMAZ (bkz. docs/authorization.md
// §3 fizibilite notu) -- yalnızca migration 0034'ün seed ettiği 6 sistem
// rolünün (owner/admin/project_manager/finance/field -- legacy_user backend
// tarafından bu listeye HİÇ dahil edilmez) izin kümesi düzenlenir. Şema
// gelecekte özel rol oluşturmayı ENGELLEMEZ, yalnızca bu sprintte UI'ı yok.
export function RolesManager({
  roles,
  permissions,
}: {
  roles: OrganizationRole[];
  permissions: Permission[];
}) {
  const [selectedId, setSelectedId] = useState(roles[0]?.id ?? "");
  const selectedRole = roles.find((r) => r.id === selectedId) ?? roles[0];

  const grouped = useMemo(() => {
    const byCategory = new Map<string, Permission[]>();
    for (const p of permissions) {
      const list = byCategory.get(p.category) ?? [];
      list.push(p);
      byCategory.set(p.category, list);
    }
    return Array.from(byCategory.entries());
  }, [permissions]);

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-[240px_1fr]">
      <Card>
        <CardHeader>Roller</CardHeader>
        <CardBody className="!p-2">
          <ul className="flex flex-col gap-1">
            {roles.map((r) => (
              <li key={r.id}>
                <button
                  type="button"
                  onClick={() => setSelectedId(r.id)}
                  className={`w-full rounded-md px-3 py-2 text-left text-sm transition-colors ${
                    r.id === selectedId ? "bg-gold-soft text-gold font-semibold" : "hover:bg-surface-hover"
                  }`}
                >
                  {r.name}
                </button>
              </li>
            ))}
          </ul>
        </CardBody>
      </Card>

      {selectedRole && (
        <RolePermissionsEditor key={selectedRole.id} role={selectedRole} grouped={grouped} />
      )}
    </div>
  );
}

function RolePermissionsEditor({
  role,
  grouped,
}: {
  role: OrganizationRole;
  grouped: [string, Permission[]][];
}) {
  const router = useRouter();
  const [selected, setSelected] = useState<Set<string>>(new Set(role.permissions));
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  // Sahip her zaman tüm yetkilere sahiptir; rolü kısmak firmayı kilitleyebilirdi
  // (backend de reddeder -- mobildeki kilitle aynı kural).
  const locked = role.code === "owner";

  function toggle(code: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(code)) next.delete(code);
      else next.add(code);
      return next;
    });
  }

  function toggleCategory(codes: string[], allChecked: boolean) {
    setSelected((prev) => {
      const next = new Set(prev);
      for (const code of codes) {
        if (allChecked) next.delete(code);
        else next.add(code);
      }
      return next;
    });
  }

  async function save() {
    setSaving(true);
    setMsg(null);
    try {
      await apiClient(`/api/v1/organization/roles/${role.id}/permissions`, {
        method: "PUT",
        body: JSON.stringify({ permissions: Array.from(selected) }),
      });
      setMsg("Kaydedildi.");
      // Sunucudan gelen rol listesi tazelenmezse başka role geçip dönünce eski
      // izinler görünüyor, bir sonraki kayıt da onları geri yazıyordu.
      router.refresh();
    } catch (err) {
      setMsg(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between">
          <span>
            {role.name}
            {role.description && (
              <span className="ml-2 text-xs font-normal normal-case text-text-muted">{role.description}</span>
            )}
          </span>
          <Badge tone="muted">{locked ? "Tüm izinler" : `${selected.size} izin`}</Badge>
        </div>
      </CardHeader>
      <CardBody>
        <div className="flex flex-col gap-5">
          {grouped.map(([category, perms]) => {
            const codes = perms.map((p) => p.code);
            const allChecked = codes.every((c) => selected.has(c));
            return (
              <div key={category}>
                <div className="mb-2 flex items-center justify-between border-b border-border pb-1.5">
                  <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">
                    {category}
                  </span>
                  {!locked && (
                    <button
                      type="button"
                      onClick={() => toggleCategory(codes, allChecked)}
                      className="text-xs text-gold hover:underline"
                    >
                      {allChecked ? "Tümünü Kaldır" : "Tümünü Seç"}
                    </button>
                  )}
                </div>
                <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                  {perms.map((p) => (
                    <label key={p.code} className="flex items-start gap-2 text-sm">
                      <input
                        type="checkbox"
                        checked={locked || selected.has(p.code)}
                        disabled={locked}
                        onChange={() => toggle(p.code)}
                        className="mt-0.5 accent-gold"
                      />
                      <span>{p.description}</span>
                    </label>
                  ))}
                </div>
              </div>
            );
          })}

          {locked ? (
            <p className="border-t border-border pt-4 text-xs text-text-muted">
              Sahip rolü kilitlidir: firmanın kendini kilitlemesini önlemek için yetkileri değiştirilemez.
            </p>
          ) : (
            <div className="flex items-center gap-3 border-t border-border pt-4">
              <Button onClick={save} disabled={saving}>
                {saving ? "Kaydediliyor…" : "Kaydet"}
              </Button>
              {msg && <p className="text-xs text-text-muted">{msg}</p>}
            </div>
          )}
        </div>
      </CardBody>
    </Card>
  );
}

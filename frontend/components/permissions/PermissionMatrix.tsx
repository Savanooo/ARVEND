"use client";

import { useMemo } from "react";

import { Select } from "@/components/ui/Select";
import { ADMIN_ROLE_ONLY_PERMISSIONS, orgRoleIsAdmin, setPermissions, togglePermission } from "@/lib/permissions";
import type { OrganizationRole, Permission } from "@/lib/types";

export interface AccessState {
  roleCode: string;
  selected: Set<string>;
}

// Kişinin rolü + o kişiye özel detaylı izinleri. Rol başlangıç noktasıdır:
// rol değişince kutucuklar o rolün varsayılanlarına döner (backend de rol
// değişiminde kişiye özel ayarları sıfırlar). Rolden farklı kutucuklar
// işaretlenir, böylece kişiye neyin özel verildiği tek bakışta görünür.
export function PermissionMatrix({
  roles,
  catalog,
  value,
  onChange,
  disabled = false,
}: {
  roles: OrganizationRole[];
  catalog: Permission[];
  value: AccessState;
  onChange: (next: AccessState) => void;
  disabled?: boolean;
}) {
  const catalogCodes = useMemo(() => new Set(catalog.map((p) => p.code)), [catalog]);
  const groups = useMemo(() => {
    const byCategory = new Map<string, Permission[]>();
    for (const p of catalog) byCategory.set(p.category, [...(byCategory.get(p.category) ?? []), p]);
    return [...byCategory.entries()];
  }, [catalog]);

  const role = roles.find((r) => r.code === value.roleCode);
  const roleDefaults = useMemo(() => new Set(role?.permissions ?? []), [role]);
  const isOwner = value.roleCode === "owner";
  const locked = disabled || isOwner || !role;
  const diffCount = [...catalogCodes].filter((c) => value.selected.has(c) !== roleDefaults.has(c)).length;
  // Kullanıcı/rol/firma ayarı yönetimi backend'de ayrıca Sahip/Yönetici
  // rolü ister; diğer rollerde bu kutucuklar değiştirilemez (backend de
  // kişiye özel eklenmelerini reddeder).
  const adminRoleOnly = (code: string) => !orgRoleIsAdmin(value.roleCode) && ADMIN_ROLE_ONLY_PERMISSIONS.has(code);
  const hasAdminRoleOnly = catalog.some((p) => adminRoleOnly(p.code));

  function changeRole(roleCode: string) {
    const next = roles.find((r) => r.code === roleCode);
    onChange({ roleCode, selected: new Set(next?.permissions ?? []) });
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <Select
          label="Rol"
          value={value.roleCode}
          disabled={disabled}
          onChange={(e) => changeRole(e.target.value)}
          required
        >
          <option value="" disabled>
            Rol seçin
          </option>
          {roles.map((r) => (
            <option key={r.code} value={r.code}>
              {r.name}
            </option>
          ))}
        </Select>
        <p className="text-xs text-text-muted">
          Rol, yetkilerin başlangıç noktasıdır. Aşağıdan bu kişiye özel ekleme veya çıkarma yapabilirsin; aynı roldeki
          diğer kişiler etkilenmez. Rol değişirse kişiye özel ayarlar sıfırlanır.
        </p>
      </div>

      {!role ? (
        <p className="rounded-md border border-border px-3 py-2 text-sm text-text-muted">
          Yetkileri düzenlemek için önce bir rol seçin.
        </p>
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border bg-surface-hover px-3 py-2 text-sm">
            <span>
              <strong>{value.selected.size}</strong> izin
              {isOwner ? (
                <span className="text-text-muted"> · Sahip her zaman tüm yetkilere sahiptir, kısıtlanamaz.</span>
              ) : diffCount > 0 ? (
                <span className="text-gold"> · rolden {diffCount} kişiye özel fark</span>
              ) : (
                <span className="text-text-muted"> · rolün varsayılanı</span>
              )}
            </span>
            {!locked && diffCount > 0 && (
              <button
                type="button"
                onClick={() => onChange({ roleCode: value.roleCode, selected: new Set(roleDefaults) })}
                className="text-xs text-gold hover:underline"
              >
                Rolün varsayılanına dön
              </button>
            )}
          </div>

          <div className="flex flex-col gap-5">
            {groups.map(([category, perms]) => {
              const codes = perms.map((p) => p.code);
              const onCount = codes.filter((c) => value.selected.has(c)).length;
              const editable = codes.filter((c) => !adminRoleOnly(c));
              const allOn = editable.every((c) => value.selected.has(c));
              return (
                <div key={category}>
                  <div className="mb-2 flex items-center justify-between border-b border-border pb-1.5">
                    <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">
                      {category} <span className="font-normal normal-case">({onCount}/{codes.length})</span>
                    </span>
                    {!locked && editable.length > 0 && (
                      <button
                        type="button"
                        onClick={() =>
                          onChange({
                            roleCode: value.roleCode,
                            selected: setPermissions(value.selected, editable, !allOn, catalogCodes),
                          })
                        }
                        className="text-xs text-gold hover:underline"
                      >
                        {allOn ? "Tümünü Kaldır" : "Tümünü Seç"}
                      </button>
                    )}
                  </div>
                  <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                    {perms.map((p) => {
                      const on = value.selected.has(p.code);
                      const added = on && !roleDefaults.has(p.code);
                      const removed = !on && roleDefaults.has(p.code);
                      const adminOnly = adminRoleOnly(p.code);
                      return (
                        <label key={p.code} className="flex items-start gap-2 text-sm">
                          <input
                            type="checkbox"
                            checked={on}
                            disabled={locked || adminOnly}
                            onChange={() =>
                              onChange({
                                roleCode: value.roleCode,
                                selected: togglePermission(value.selected, p.code, catalogCodes),
                              })
                            }
                            className="mt-0.5 accent-gold"
                          />
                          <span>
                            <span
                              className={removed ? "text-text-muted line-through" : adminOnly ? "text-text-muted" : ""}
                            >
                              {p.description}
                            </span>
                            {added && <span className="ml-1.5 text-xs font-semibold text-success">+ kişiye özel</span>}
                            {removed && <span className="ml-1.5 text-xs font-semibold text-danger">− kişiye özel</span>}
                            {adminOnly && <span className="ml-1.5 text-xs text-text-muted">(yalnızca Sahip/Yönetici)</span>}
                          </span>
                        </label>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </div>
          <p className="text-xs text-text-muted">
            Bir yazma iznini açtığında aynı bölümün görüntüleme izni de açılır; görüntülemeyi kapatınca ona bağlı yazma
            izinleri de kapanır. Böylece kimse göremediği bir şeyi düzenlemeye çalışmaz.
            {hasAdminRoleOnly &&
              " Kullanıcı, rol ve firma ayarı yönetimi yalnızca Sahip veya Yönetici rolündeki kişilere verilebilir."}
          </p>
        </>
      )}
    </div>
  );
}

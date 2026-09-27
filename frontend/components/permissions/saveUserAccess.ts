import { apiClient } from "@/lib/api";
import type { OrganizationRole, UserPermissions } from "@/lib/types";

import type { AccessState } from "./PermissionMatrix";

export function sameSet(a: ReadonlySet<string>, b: ReadonlySet<string>): boolean {
  return a.size === b.size && [...a].every((x) => b.has(x));
}

/**
 * Atanabilir roller listesi (GET /organization/roles) "Eski Sistem"
 * (legacy_user) rolünü içermez. O roldeki bir kişinin kartında rol kutusu
 * listedeki ilk role (ör. Finans) düşmesin ve rol varsayılanlarına göre
 * kişiye özel ayar yapılabilsin diye mevcut rol seçenek olarak eklenir.
 */
export function rolesWithCurrent(roles: OrganizationRole[], detail: UserPermissions | null): OrganizationRole[] {
  if (!detail?.role_code || roles.some((r) => r.code === detail.role_code)) return roles;
  return [
    ...roles,
    {
      id: `mevcut-${detail.role_code}`,
      code: detail.role_code,
      name: `${detail.role_name || detail.role_code} (mevcut rol)`,
      description: "",
      is_system: true,
      permissions: detail.role_permissions,
    },
  ];
}

/**
 * Önce rolü (değiştiyse), sonra kişiye özel izinleri kaydeder. Sıra önemli:
 * backend rol değişiminde eski kişiye özel ayarları sıfırlar, izinler yeni
 * role göre fark olarak yazılır. Sahip'e kişiye özel izin yazılmaz.
 */
export async function saveUserAccess(userId: string, savedRoleCode: string, access: AccessState): Promise<void> {
  if (access.roleCode !== savedRoleCode) {
    await apiClient(`/api/v1/users/${userId}/organization-role`, {
      method: "PUT",
      body: JSON.stringify({ role_code: access.roleCode }),
    });
  }
  if (access.roleCode !== "owner") {
    await apiClient<UserPermissions>(`/api/v1/users/${userId}/permissions`, {
      method: "PUT",
      body: JSON.stringify({ permissions: [...access.selected] }),
    });
  }
}

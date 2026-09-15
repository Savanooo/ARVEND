import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { OrganizationRole, Permission } from "@/lib/types";

import { RolesManager } from "./RolesManager";

export default async function RollerPage() {
  const cookieHeader = (await cookies()).toString();
  const [rolesRes, permissionsRes] = await Promise.all([
    apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader),
    apiServer<{ permissions: Permission[] }>("/api/v1/organization/permissions", cookieHeader),
  ]);

  return (
    <>
      <PageHeader title="Roller & Yetkiler" />
      <div className="p-8">
        <RolesManager roles={rolesRes.roles} permissions={permissionsRes.permissions} />
      </div>
    </>
  );
}

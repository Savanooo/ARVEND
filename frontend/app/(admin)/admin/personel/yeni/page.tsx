import { redirect } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { OrganizationRole, Permission, User } from "@/lib/types";

import { fetchAllUsers } from "../fetchAllUsers";
import { NewEmployeeForm } from "./NewEmployeeForm";

export default async function YeniPersonelPage() {
  const me = await requirePagePermission(PAGE_PERMISSIONS.employees);
  if (!canAccess(me, "employees.manage")) redirect("/admin/personel");
  const cookieHeader = (await cookies()).toString();

  const canLinkUsers = canAccess(me, PAGE_PERMISSIONS.users);
  const canReadAccess = canAccess(me, PAGE_PERMISSIONS.roles);
  const canEditAccess = canAccess(me, "organization.roles.manage");
  const canCreateLogin = canReadAccess && canEditAccess && canAccess(me, "organization.users.manage");

  const [users, rolesRes, catalogRes] = await Promise.all([
    canLinkUsers ? fetchAllUsers(cookieHeader) : Promise.resolve([] as User[]),
    canReadAccess
      ? apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader)
      : Promise.resolve({ roles: [] as OrganizationRole[] }),
    canReadAccess
      ? apiServer<{ permissions: Permission[] }>("/api/v1/organization/permissions", cookieHeader)
      : Promise.resolve({ permissions: [] as Permission[] }),
  ]);

  return (
    <>
      <PageHeader title="Yeni Personel" />
      <div className="p-8">
        <NewEmployeeForm
          users={users}
          roles={rolesRes.roles}
          catalog={catalogRes.permissions}
          canLinkUsers={canLinkUsers}
          canReadAccess={canReadAccess}
          canEditAccess={canEditAccess}
          canCreateLogin={canCreateLogin}
        />
      </div>
    </>
  );
}

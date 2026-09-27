import { cookies } from "next/headers";

import { UserAccessCard } from "@/components/permissions/UserAccessCard";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { OrganizationRole, Permission, User, UserPermissions, UserProjectAssignment } from "@/lib/types";

import { EditUserForm } from "./EditUserForm";

export default async function KullaniciDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.users);
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const canReadAccess = canAccess(me, PAGE_PERMISSIONS.roles);

  const [user, projectsRes, rolesRes, catalogRes, access] = await Promise.all([
    apiServer<User>(`/api/v1/users/${id}`, cookieHeader),
    apiServer<{ projects: UserProjectAssignment[] }>(`/api/v1/users/${id}/projects`, cookieHeader),
    canReadAccess
      ? apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader)
      : Promise.resolve({ roles: [] as OrganizationRole[] }),
    canReadAccess
      ? apiServer<{ permissions: Permission[] }>("/api/v1/organization/permissions", cookieHeader)
      : Promise.resolve({ permissions: [] as Permission[] }),
    canReadAccess ? apiServer<UserPermissions>(`/api/v1/users/${id}/permissions`, cookieHeader) : Promise.resolve(null),
  ]);

  return (
    <>
      <PageHeader title={user.full_name} />
      <div className="grid grid-cols-1 items-start gap-6 p-8 xl:grid-cols-[minmax(0,28rem)_minmax(0,1fr)]">
        <EditUserForm
          user={user}
          projects={projectsRes.projects}
          canManage={canAccess(me, "organization.users.manage")}
        />
        {access && (
          <UserAccessCard
            userId={user.id}
            username={user.username}
            initial={access}
            roles={rolesRes.roles}
            catalog={catalogRes.permissions}
            canEdit={canAccess(me, "organization.roles.manage")}
          />
        )}
      </div>
    </>
  );
}

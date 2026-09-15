import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { OrganizationRole, User, UserProjectAssignment } from "@/lib/types";

import { EditUserForm } from "./EditUserForm";

export default async function KullaniciDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const [user, rolesRes, projectsRes] = await Promise.all([
    apiServer<User>(`/api/v1/users/${id}`, cookieHeader),
    apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader),
    apiServer<{ projects: UserProjectAssignment[] }>(`/api/v1/users/${id}/projects`, cookieHeader),
  ]);

  return (
    <>
      <PageHeader title={user.full_name} />
      <div className="p-8">
        <EditUserForm user={user} roles={rolesRes.roles} projects={projectsRes.projects} />
      </div>
    </>
  );
}

import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { OrganizationRole } from "@/lib/types";

import { NewUserForm } from "./NewUserForm";

export default async function YeniKullaniciPage() {
  const cookieHeader = (await cookies()).toString();
  const { roles } = await apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader);

  return (
    <>
      <PageHeader title="Yeni Kullanıcı" />
      <div className="p-8">
        <NewUserForm roles={roles} />
      </div>
    </>
  );
}

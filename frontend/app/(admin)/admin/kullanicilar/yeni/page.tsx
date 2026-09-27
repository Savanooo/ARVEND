import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { OrganizationRole } from "@/lib/types";

import { NewUserForm } from "./NewUserForm";

export default async function YeniKullaniciPage() {
  const me = await requirePagePermission(PAGE_PERMISSIONS.users);
  // Form rol listesini de çeker (Roller görüntüleme) ve hesabı açar
  // (Kullanıcıları düzenleme); biri eksikse sayfa backend 403'ü ile çökmek
  // yerine listeye döner.
  if (!canAccess(me, "organization.users.manage") || !canAccess(me, PAGE_PERMISSIONS.roles)) {
    redirect("/admin/kullanicilar");
  }
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

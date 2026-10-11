import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import { unlinkedActiveEmployees } from "@/lib/person-link";
import type { Employee, OrganizationRole } from "@/lib/types";

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
  // Kişi = tek kayıt: personel kaydı açmak/bağlamak "Personeli düzenleme"
  // ister (backend izin yoksa adımı atlar); bağlanabilecek personeli
  // listelemek ayrıca "Personeli görüntüleme". Liste alınamazsa form yine
  // açılır, backend varsayılanı uygulanır (bkz. NewUserForm).
  const canManageEmployees = canAccess(me, "employees.manage");
  const canListEmployees = canManageEmployees && canAccess(me, PAGE_PERMISSIONS.employees);
  const [{ roles }, unlinked] = await Promise.all([
    apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader),
    canListEmployees
      ? apiServer<{ employees: Employee[] }>("/api/v1/employees?filter=aktif", cookieHeader)
          .then((r) => unlinkedActiveEmployees(r.employees))
          .catch(() => "error" as const)
      : Promise.resolve(null),
  ]);

  return (
    <>
      <PageHeader title="Yeni Kullanıcı" />
      <div className="p-8">
        <NewUserForm
          roles={roles}
          canManageEmployees={canManageEmployees}
          unlinkedEmployees={unlinked === "error" ? null : unlinked}
          employeesError={unlinked === "error"}
        />
      </div>
    </>
  );
}

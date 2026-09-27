import { cookies } from "next/headers";

import { CreateLoginCard } from "@/components/permissions/CreateLoginCard";
import { UserAccessCard } from "@/components/permissions/UserAccessCard";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { Employee, OrganizationRole, Permission, User, UserPermissions } from "@/lib/types";

import { EditEmployeeForm } from "./EditEmployeeForm";

export default async function PersonelDetayPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ uyari?: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.employees);
  const { id } = await params;
  const { uyari } = await searchParams;
  const cookieHeader = (await cookies()).toString();

  // Ek veriler yalnızca izin varsa çekilir: kişiye özel yetkiler "personeli
  // görür ama kullanıcıları/rolleri görmez" gibi kombinasyonlara izin verir
  // ve bu ekran o durumda çökmek yerine ilgili bölümü göstermez.
  const canReadUsers = canAccess(me, PAGE_PERMISSIONS.users);
  const canReadAccess = canAccess(me, PAGE_PERMISSIONS.roles);
  const canEditAccess = canAccess(me, "organization.roles.manage");
  const canManageEmployee = canAccess(me, "employees.manage");
  // Hesap açma kartı rol listesini ve izin kataloğunu da gösterir
  // (Rolleri görüntüleme); biri eksikse kart boş bir rol kutusuyla kalırdı.
  const canCreateLogin =
    canReadAccess && canEditAccess && canManageEmployee && canAccess(me, "organization.users.manage");

  const [employee, usersResult, rolesRes, catalogRes] = await Promise.all([
    apiServer<Employee>(`/api/v1/employees/${id}`, cookieHeader),
    canReadUsers
      ? apiServer<{ users: User[]; total: number }>("/api/v1/users", cookieHeader)
      : Promise.resolve({ users: [] as User[], total: 0 }),
    canReadAccess
      ? apiServer<{ roles: OrganizationRole[] }>("/api/v1/organization/roles", cookieHeader)
      : Promise.resolve({ roles: [] as OrganizationRole[] }),
    canReadAccess
      ? apiServer<{ permissions: Permission[] }>("/api/v1/organization/permissions", cookieHeader)
      : Promise.resolve({ permissions: [] as Permission[] }),
  ]);
  const access =
    employee.user_id && canReadAccess
      ? await apiServer<UserPermissions>(`/api/v1/users/${employee.user_id}/permissions`, cookieHeader)
      : null;
  const linkedUser = usersResult.users.find((u) => u.id === employee.user_id);

  return (
    <>
      <PageHeader title={employee.full_name} />
      <div className="grid grid-cols-1 items-start gap-6 p-8 xl:grid-cols-[minmax(0,28rem)_minmax(0,1fr)]">
        <EditEmployeeForm
          key={employee.user_id ?? "baglantisiz"}
          employee={employee}
          users={usersResult.users}
          canManage={canManageEmployee}
          canLinkUsers={canReadUsers}
        />
        <div className="flex flex-col gap-4">
          {uyari === "yetki" && (
            <p className="rounded-md border border-danger/40 bg-danger/5 px-4 py-3 text-sm">
              Personel kaydedildi ama kişiye özel yetkiler kaydedilemedi. Aşağıdan tekrar kaydedebilirsin.
            </p>
          )}
          {access && employee.user_id ? (
            <UserAccessCard
              key={employee.user_id}
              userId={employee.user_id}
              username={linkedUser?.username}
              initial={access}
              roles={rolesRes.roles}
              catalog={catalogRes.permissions}
              canEdit={canEditAccess}
            />
          ) : !employee.user_id && canCreateLogin ? (
            <CreateLoginCard employee={employee} roles={rolesRes.roles} catalog={catalogRes.permissions} />
          ) : (
            <p className="rounded-md border border-border px-4 py-3 text-sm text-text-muted">
              {!employee.user_id
                ? "Bu personelin sisteme giriş hesabı yok."
                : me.role === "admin"
                  ? "Bu personelin giriş hesabı var; rol ve yetkilerini görmek için rolünde \"Rolleri görüntüleme\" izni olmalı."
                  : "Bu personelin sisteme giriş hesabı var."}
            </p>
          )}
        </div>
      </div>
    </>
  );
}

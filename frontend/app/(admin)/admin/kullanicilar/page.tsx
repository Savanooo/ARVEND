import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { User } from "@/lib/types";

async function fetchUsers() {
  const cookieHeader = (await cookies()).toString();
  return apiServer<{ users: User[]; total: number }>(
    "/api/v1/users",
    cookieHeader
  );
}

export default async function KullanicilarPage() {
  const me = await requirePagePermission(PAGE_PERMISSIONS.users);
  const { users } = await fetchUsers();
  const canManage = canAccess(me, "organization.users.manage");
  // Yeni kullanıcı formu rol listesini de çeker (bkz. yeni/page.tsx kapısı).
  const canCreate = canManage && canAccess(me, PAGE_PERMISSIONS.roles);

  return (
    <>
      <PageHeader
        title="Kullanıcılar"
        action={
          canCreate ? (
            <Link href="/admin/kullanicilar/yeni">
              <Button>+ Yeni Kullanıcı</Button>
            </Link>
          ) : undefined
        }
      />
      <div className="p-8">
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Ad Soyad</Th>
                <Th>Kullanıcı Adı</Th>
                <Th>Organizasyon Rolü</Th>
                <Th>Durum</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {users.map((u) => (
                <Tr key={u.id}>
                  <Td className="font-medium">{u.full_name}</Td>
                  <Td className="text-text-muted">{u.username}</Td>
                  <Td>
                    {/* organization_role_name — RBAC/Project Membership
                        sprint'inin ince-taneli rolü (owner/admin/project_
                        manager/finance/field). Boşsa (nadiren, henüz
                        backfill edilmemiş bir kayıt) eski kaba rol (admin/
                        kullanici) yedek olarak gösterilir. */}
                    <Badge tone={u.organization_role_code === "owner" || u.organization_role_code === "admin" ? "gold" : "muted"}>
                      {u.organization_role_name || (u.role === "admin" ? "Yönetici" : "Kullanıcı")}
                    </Badge>
                  </Td>
                  <Td>
                    <Badge tone={u.is_active ? "success" : "danger"}>
                      {u.is_active ? "Aktif" : "Pasif"}
                    </Badge>
                  </Td>
                  <Td>
                    <Link
                      href={`/admin/kullanicilar/${u.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      {canManage ? "Düzenle" : "Görüntüle"}
                    </Link>
                  </Td>
                </Tr>
              ))}
              {users.length === 0 && (
                <tr>
                  <Td colSpan={5} className="text-center text-text-muted">
                    Henüz kullanıcı yok.
                  </Td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
      </div>
    </>
  );
}

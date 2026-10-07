import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Pagination } from "@/components/ui/Pagination";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { User } from "@/lib/types";

// Eskiden sayfa gönderilmiyordu: backend en yeni 50 kullanıcıyı döndüğü
// için en eskiler (Sahip dahil) listede hiç görünmüyordu.
const PAGE_SIZE = 50;
// Backend OFFSET'i int32 hesaplar -- uçuk bir ?page= taşıp 500'e dönmesin.
const MAX_PAGE = 100_000;

function parsePage(raw: string | undefined): number {
  const n = Math.floor(Number(raw));
  if (!Number.isFinite(n) || n < 1) return 1;
  return Math.min(n, MAX_PAGE);
}

async function fetchUsers(page: number) {
  const cookieHeader = (await cookies()).toString();
  return apiServer<{ users: User[]; total: number }>(
    `/api/v1/users?page=${page}&limit=${PAGE_SIZE}`,
    cookieHeader
  );
}

function pageHref(target: number) {
  return target > 1 ? `/admin/kullanicilar?page=${target}` : "/admin/kullanicilar";
}

export default async function KullanicilarPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.users);
  const page = parsePage((await searchParams).page);
  const { users, total } = await fetchUsers(page);
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
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
      <div className="flex flex-col gap-4 p-8">
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
                    {total === 0 ? "Henüz kullanıcı yok." : "Bu sayfada kullanıcı yok."}
                  </Td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
        <Pagination page={page} totalPages={totalPages} total={total} itemLabel="kullanıcı" hrefForPage={pageHref} />
      </div>
    </>
  );
}

import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import type { User } from "@/lib/types";

async function fetchUsers() {
  const cookieHeader = (await cookies()).toString();
  return apiServer<{ users: User[]; total: number }>(
    "/api/v1/users",
    cookieHeader
  );
}

export default async function KullanicilarPage() {
  const { users } = await fetchUsers();

  return (
    <>
      <Topbar
        title="Kullanıcılar"
        action={
          <Link href="/admin/kullanicilar/yeni">
            <Button>+ Yeni Kullanıcı</Button>
          </Link>
        }
      />
      <div className="p-8">
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Ad Soyad</Th>
                <Th>Kullanıcı Adı</Th>
                <Th>Rol</Th>
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
                    <Badge tone={u.role === "admin" ? "gold" : "muted"}>
                      {u.role === "admin" ? "Yönetici" : "Kullanıcı"}
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
                      Düzenle
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

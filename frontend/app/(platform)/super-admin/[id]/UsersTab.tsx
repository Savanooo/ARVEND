import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import type { User } from "@/lib/types";

export function UsersTab({ users }: { users: User[] }) {
  if (users.length === 0) {
    return <EmptyState title="Henüz kullanıcı yok" />;
  }
  return (
    <div className="pt-2">
      <Table>
        <thead>
          <tr>
            <Th>Ad Soyad</Th>
            <Th>Kullanıcı Adı</Th>
            <Th>Rol</Th>
            <Th>Durum</Th>
            <Th>İlk Şifre</Th>
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
                <Badge tone={u.is_active ? "success" : "danger"}>{u.is_active ? "Aktif" : "Pasif"}</Badge>
              </Td>
              <Td>
                {u.must_change_password && <Badge tone="info">Değiştirmeli</Badge>}
              </Td>
            </Tr>
          ))}
        </tbody>
      </Table>
    </div>
  );
}

import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiServer } from "@/lib/api";
import type { Plan } from "@/lib/types";

// Salt okunur: backend'de yalnızca GET /platform/plans var (plan CRUD ucu
// yok); max_users/max_projects bugün hiçbir yerde uygulanmıyor (bkz.
// migration 0031) -- boş/0 değer "—" olarak gösterilir, sınır UYDURULMAZ.
// Bir firmanın planı firma detayından (PATCH .../plan) değiştirilir.
function limit(value: number): string {
  return value > 0 ? String(value) : "—";
}

export default async function PlanlarPage() {
  const cookieHeader = (await cookies()).toString();
  const { plans } = await apiServer<{ plans: Plan[] }>("/api/v1/platform/plans", cookieHeader);
  const sorted = [...plans].sort((a, b) => a.sort_order - b.sort_order);

  return (
    <>
      <PageHeader title="Planlar" />
      <div className="flex flex-col gap-4 p-8">
        <p className="text-sm text-text-muted">
          Plan tanımları salt okunurdur; bir firmanın planını firma detayından değiştirebilirsiniz.
          Kullanıcı/proje sınırları henüz uygulanmamaktadır.
        </p>
        <Card>
          {sorted.length === 0 ? (
            <EmptyState title="Plan bulunamadı" description="Tanımlı bir platform planı yok." />
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Kod</Th>
                  <Th>Ad</Th>
                  <Th>Durum</Th>
                  <Th>Maks. Kullanıcı</Th>
                  <Th>Maks. Proje</Th>
                </tr>
              </thead>
              <tbody>
                {sorted.map((plan) => (
                  <Tr key={plan.code}>
                    <Td className="font-mono text-text-muted">{plan.code}</Td>
                    <Td className="font-medium">{plan.name}</Td>
                    <Td className="text-text-muted">{plan.is_active ? "Aktif" : "Pasif"}</Td>
                    <Td className="text-text-muted">{limit(plan.max_users)}</Td>
                    <Td className="text-text-muted">{limit(plan.max_projects)}</Td>
                  </Tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      </div>
    </>
  );
}

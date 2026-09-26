import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatTL } from "@/lib/format";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import type { Employee } from "@/lib/types";

async function fetchEmployees(filter: string) {
  const cookieHeader = (await cookies()).toString();
  const qs = filter ? `?filter=${encodeURIComponent(filter)}` : "";
  return apiServer<{ employees: Employee[] }>(`/api/v1/employees${qs}`, cookieHeader);
}

export default async function PersonelPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string }>;
}) {
  await requirePagePermission(PAGE_PERMISSIONS.employees);
  const { filter = "" } = await searchParams;
  const { employees } = await fetchEmployees(filter);

  return (
    <>
      <PageHeader
        title="Personel"
        action={
          <Link href="/admin/personel/yeni">
            <Button>+ Yeni Personel</Button>
          </Link>
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Ad Soyad</Th>
                <Th>Görev</Th>
                <Th>Telefon</Th>
                <Th className="text-right">Yevmiye / Maaş</Th>
                <Th>Durum</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {employees.map((e) => (
                <Tr key={e.id}>
                  <Td className="font-medium">{e.full_name}</Td>
                  <Td className="text-text-muted">{e.position || "—"}</Td>
                  <Td className="text-text-muted">{e.phone || "—"}</Td>
                  <Td className="text-right font-medium">
                    {e.daily_wage != null
                      ? `${formatTL(e.daily_wage)} / gün`
                      : e.salary != null
                        ? `${formatTL(e.salary)} / ay`
                        : "—"}
                  </Td>
                  <Td>
                    <Badge tone={e.is_active ? "success" : "muted"}>
                      {e.is_active ? "Aktif" : "Pasif"}
                    </Badge>
                  </Td>
                  <Td className="text-right">
                    <Link
                      href={`/admin/personel/${e.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      Düzenle
                    </Link>
                  </Td>
                </Tr>
              ))}
              {employees.length === 0 && (
                <tr>
                  <Td colSpan={6} className="text-center text-text-muted">
                    Personel bulunamadı.
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

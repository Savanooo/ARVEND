import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Pagination } from "@/components/ui/Pagination";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiServer } from "@/lib/api";
import { ORG_STATUS } from "@/lib/status";
import type { Organization } from "@/lib/types";

import { StatusFilterTabs, type OrgListFilter } from "./StatusFilterTabs";

const PAGE_SIZE = 20;

export default async function SuperAdminOrganizationsPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; page?: string }>;
}) {
  const params = await searchParams;
  const status = (params.status ?? "") as OrgListFilter;
  const page = Math.max(1, parseInt(params.page ?? "1") || 1);

  const cookieHeader = (await cookies()).toString();
  const { organizations, total } = await apiServer<{ organizations: Organization[]; total: number }>(
    `/api/v1/platform/organizations?status=${status}&page=${page}&limit=${PAGE_SIZE}`,
    cookieHeader
  );
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <>
      <PageHeader
        title="Firmalar"
        action={
          <Link href="/super-admin/yeni">
            <Button>+ Yeni Firma</Button>
          </Link>
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <StatusFilterTabs current={status} />
        {status === "deleted" && (
          <p className="text-xs text-text-muted">
            Bu firmalar silinmiştir: erişimleri kapalı, normal listede görünmezler. Tüm verileri (kullanıcılar,
            projeler, teklifler, finans) korunur; firma detayından geri yüklenebilir.
          </p>
        )}
        <Card>
          {organizations.length === 0 ? (
            <EmptyState title="Firma bulunamadı" description="Bu filtreye uyan bir firma yok." />
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Firma</Th>
                  <Th>Slug</Th>
                  <Th>Durum</Th>
                  <Th>Plan</Th>
                  <Th>Onboarding</Th>
                  <Th>Oluşturulma</Th>
                </tr>
              </thead>
              <tbody>
                {organizations.map((org) => (
                  <Tr key={org.id}>
                    <Td className="font-medium">
                      <Link href={`/super-admin/${org.id}`} className="hover:text-gold hover:underline">
                        {org.name}
                      </Link>
                    </Td>
                    <Td className="text-text-muted">{org.slug}</Td>
                    <Td>
                      <span className="flex items-center gap-2">
                        <StatusBadge status={org.status} registry={ORG_STATUS} />
                        {org.deleted_at && <Badge tone="danger">Silindi</Badge>}
                      </span>
                    </Td>
                    <Td className="text-text-muted">{org.plan_code}</Td>
                    <Td className="text-text-muted">
                      {org.onboarding_completed ? "Tamamlandı" : "Devam ediyor"}
                    </Td>
                    <Td className="text-text-muted">
                      {new Date(org.created_at).toLocaleDateString("tr-TR")}
                    </Td>
                  </Tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
        <Pagination
          page={page}
          totalPages={totalPages}
          total={total}
          itemLabel="firma"
          hrefForPage={(p) => `/super-admin?status=${status}&page=${p}`}
        />
      </div>
    </>
  );
}

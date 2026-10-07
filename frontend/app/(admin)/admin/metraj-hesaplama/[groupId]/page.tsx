import Link from "next/link";
import { notFound } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/Card";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { CalcCategory, CalcGroup } from "@/lib/types";

import { EditGroupForm } from "./EditGroupForm";
import { NewCategoryButton } from "./NewCategoryButton";

// Tekil grup/kategori GET uçları yok (admin ekranı için ayrı bir uç
// açmak yerine, zaten küçük olan listeden id ile bulmak yeterli --
// bkz. backend router.go: yalnızca ListGroups/ListCategoriesByGroup var).
// include_inactive: pasif grup/kategoriler de gelir -- aksi halde pasife
// alınan grubun sayfası 404 verir, yeniden aktifleştirilemezdi.
async function fetchGroup(groupId: string) {
  const cookieHeader = (await cookies()).toString();
  const [{ groups }, { categories }] = await Promise.all([
    apiServer<{ groups: CalcGroup[] }>("/api/v1/calculations/groups?include_inactive=1", cookieHeader),
    apiServer<{ categories: CalcCategory[] }>(
      `/api/v1/calculations/categories?group_id=${encodeURIComponent(groupId)}&include_inactive=1`,
      cookieHeader
    ),
  ]);
  const group = groups.find((g) => g.id === groupId);
  return { group, categories };
}

export default async function GroupDetailPage({
  params,
}: {
  params: Promise<{ groupId: string }>;
}) {
  // Her iki liste ucu da calculations.read ister -- bu kapı ikisini de
  // garanti eder; düzenleme/yeni kategori yalnızca calculations.manage ile.
  const me = await requirePagePermission(PAGE_PERMISSIONS.calculations);
  const { groupId } = await params;
  const { group, categories } = await fetchGroup(groupId);
  if (!group) notFound();
  const canManage = canAccess(me, "calculations.manage");

  return (
    <>
      <PageHeader
        title={
          <span>
            <Link href="/admin/metraj-hesaplama" className="text-text-muted hover:underline">
              Metraj Hesaplama
            </Link>{" "}
            / {group.name}
            {!group.is_active && (
              <span className="ml-2 align-middle">
                <StatusBadge status="inactive" registry={CATEGORY_STATUS} />
              </span>
            )}
          </span>
        }
        action={canManage ? <NewCategoryButton groupId={group.id} /> : undefined}
      />
      <div className="flex flex-col gap-6 p-8">
        {!group.is_active && (
          <p className="rounded-md border border-border bg-surface-hover p-3 text-sm text-text-muted">
            Bu grup pasif: Metraj Hesapla panelinde görünmez.{" "}
            {canManage ? "Yeniden kullanmak için aşağıdan \"Aktif\" kutusunu işaretleyip kaydedin." : ""}
          </p>
        )}
        <EditGroupForm group={group} canManage={canManage} />
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Hesaplama Türü</Th>
                <Th>Slug</Th>
                <Th>Durum</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {categories.map((c) => (
                <Tr key={c.id}>
                  <Td className={`font-medium ${c.is_active ? "" : "text-text-muted"}`}>{c.name}</Td>
                  <Td className="text-text-muted">{c.slug}</Td>
                  <Td>
                    <StatusBadge status={c.is_active ? "active" : "inactive"} registry={CATEGORY_STATUS} />
                  </Td>
                  <Td className="text-right">
                    <Link
                      href={`/admin/metraj-hesaplama/${group.id}/${c.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      Reçete →
                    </Link>
                  </Td>
                </Tr>
              ))}
              {categories.length === 0 && (
                <tr>
                  <Td colSpan={4} className="text-center text-text-muted">
                    Bu grupta henüz hesaplama türü yok.
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

const CATEGORY_STATUS = {
  active: { label: "Aktif", tone: "success" as const },
  inactive: { label: "Pasif", tone: "muted" as const },
};

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
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import { employeeLoginDisabled } from "@/lib/person-link";
import type { Employee, EmployeeLinkSuggestion } from "@/lib/types";

import { LinkSuggestionsCard } from "./LinkSuggestionsCard";

async function fetchEmployees(filter: string) {
  const cookieHeader = (await cookies()).toString();
  const qs = filter ? `?filter=${encodeURIComponent(filter)}` : "";
  return apiServer<{ employees: Employee[] }>(`/api/v1/employees${qs}`, cookieHeader);
}

// Hesap <-> personel eşleşme önerileri (kişi = tek kayıt). Yardımcı bir
// kart: alınamazsa liste ekranının asıl işini bölmeden hiç gösterilmez.
async function fetchLinkSuggestions(): Promise<EmployeeLinkSuggestion[]> {
  const cookieHeader = (await cookies()).toString();
  try {
    const { suggestions } = await apiServer<{ suggestions: EmployeeLinkSuggestion[] }>(
      "/api/v1/employees/link-suggestions",
      cookieHeader
    );
    return suggestions ?? [];
  } catch {
    return [];
  }
}

export default async function PersonelPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.employees);
  const { filter = "" } = await searchParams;
  // "Personeli görüntüleme" mesai girişi için de verilir: ekleme/düzenleme
  // ve ücret sütunu yalnızca "Personeli düzenleme" ile.
  const canManage = canAccess(me, "employees.manage");
  // Bağlı hesabın kullanıcı adı yalnızca kullanıcı listesini görebilene
  // gelir; öneriler de hesap adlarını gösterdiği için aynı izni ister.
  const canReadUsers = canAccess(me, PAGE_PERMISSIONS.users);
  const [{ employees }, suggestions] = await Promise.all([
    fetchEmployees(filter),
    canManage && canReadUsers ? fetchLinkSuggestions() : Promise.resolve([] as EmployeeLinkSuggestion[]),
  ]);

  return (
    <>
      <PageHeader
        title="Personel"
        action={
          canManage ? (
            <Link href="/admin/personel/yeni">
              <Button>+ Yeni Personel</Button>
            </Link>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-4 p-8">
        {suggestions.length > 0 && <LinkSuggestionsCard suggestions={suggestions} />}
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Ad Soyad</Th>
                <Th>Görev</Th>
                <Th>Telefon</Th>
                {canManage && <Th className="text-right">Yevmiye / Maaş</Th>}
                <Th>Giriş Hesabı</Th>
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
                  {canManage && (
                    <Td className="text-right font-medium">
                      {e.daily_wage != null
                        ? `${formatTL(e.daily_wage)} / gün`
                        : e.salary != null
                          ? `${formatTL(e.salary)} / ay`
                          : "—"}
                    </Td>
                  )}
                  <Td>
                    <LoginCell employee={e} canOpenUser={canReadUsers} />
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
                      {canManage ? "Düzenle" : "Görüntüle"}
                    </Link>
                  </Td>
                </Tr>
              ))}
              {employees.length === 0 && (
                <tr>
                  <Td colSpan={canManage ? 7 : 6} className="text-center text-text-muted">
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

// Bağlı giriş hesabı (kişi = tek kayıt). Kullanıcı adı yalnızca kullanıcı
// listesini görebilene gelir; diğerleri yalnızca "hesabı var"ı görür.
function LoginCell({ employee: e, canOpenUser }: { employee: Employee; canOpenUser: boolean }) {
  if (!e.user_id) return <span className="text-text-muted">—</span>;
  if (!e.user_username) return <span className="text-text-muted">Giriş hesabı var</span>;
  return (
    <span className="flex items-center gap-2">
      {canOpenUser && !e.user_deleted ? (
        <Link href={`/admin/kullanicilar/${e.user_id}`} className="hover:text-gold hover:underline">
          {e.user_username}
        </Link>
      ) : (
        <span>{e.user_username}</span>
      )}
      {employeeLoginDisabled(e) && <Badge tone="gold">Giriş kapalı</Badge>}
    </span>
  );
}

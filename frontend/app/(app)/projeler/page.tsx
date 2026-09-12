import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Card } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import { formatTL } from "@/lib/format";
import { PROJECT_STATUS_LABELS, type Project, type ProjectStatus } from "@/lib/types";

import { ProjectFilters } from "./ProjectFilters";

const STATUS_TONE: Record<ProjectStatus, "muted" | "gold" | "success" | "danger"> = {
  planned: "muted",
  active: "gold",
  paused: "muted",
  completed: "success",
  cancelled: "danger",
};

const PAGE_SIZE = 25;

// Finans modülleri (tahsilat/masraf/fatura) henüz yok. Bu kolonlar
// altyapıda yerini almış durumda ama UYDURMA değer göstermiyoruz --
// "0 TL tahsil edildi" demek, gerçekte hiç tahsilat kaydı olmadığı için
// yanlış bilgi olurdu. Sonraki fazlarda gerçek hesaplamaya bağlanacak.
const NO_DATA = "—";

export default async function ProjelerPage({
  searchParams,
}: {
  searchParams: Promise<{
    status?: string;
    q?: string;
    project_type?: string;
    currency?: string;
    start_from?: string;
    page?: string;
  }>;
}) {
  const sp = await searchParams;
  const page = Math.max(1, Number(sp.page ?? "1") || 1);

  const query = new URLSearchParams({ page: String(page), limit: String(PAGE_SIZE) });
  for (const key of ["status", "q", "project_type", "currency", "start_from"] as const) {
    if (sp[key]) query.set(key, sp[key]!);
  }

  const cookieHeader = (await cookies()).toString();
  const { projects, total } = await apiServer<{ projects: Project[]; total: number }>(
    `/api/v1/projects?${query.toString()}`,
    cookieHeader
  );

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  function pageHref(target: number) {
    const q = new URLSearchParams(query);
    q.set("page", String(target));
    q.delete("limit");
    return `/projeler?${q.toString()}`;
  }

  return (
    <>
      <Topbar title="Projeler" />
      <div className="flex flex-col gap-4 p-8">
        <ProjectFilters
          status={sp.status ?? ""}
          search={sp.q ?? ""}
          projectType={sp.project_type ?? ""}
          currency={sp.currency ?? ""}
          startFrom={sp.start_from ?? ""}
        />

        <Card>
          <div className="overflow-x-auto">
            <Table>
              <thead>
                <tr>
                  <Th>Proje No</Th>
                  <Th>Proje Adı</Th>
                  <Th>Müşteri</Th>
                  <Th>Proje Tipi</Th>
                  <Th>Başlangıç</Th>
                  <Th className="text-right">Proje Bedeli</Th>
                  <Th>PB</Th>
                  <Th className="text-right">Tahsil Edilen</Th>
                  <Th className="text-right">Bakiye</Th>
                  <Th className="text-right">Toplam Masraf</Th>
                  <Th className="text-right">Brüt Kâr</Th>
                  <Th>Fatura</Th>
                  <Th>Durum</Th>
                </tr>
              </thead>
              <tbody>
                {projects.map((p) => (
                  <Tr key={p.id}>
                    <Td>
                      <Link
                        href={`/projeler/${p.id}`}
                        className="font-medium hover:text-gold hover:underline"
                      >
                        {p.project_no}
                      </Link>
                    </Td>
                    <Td className="font-medium">{p.name}</Td>
                    <Td className="text-text-muted">{p.customer_name}</Td>
                    <Td className="text-text-muted">{p.project_type || NO_DATA}</Td>
                    <Td className="text-text-muted">
                      {p.start_date ? new Date(p.start_date).toLocaleDateString("tr-TR") : NO_DATA}
                    </Td>
                    <Td className="text-right font-medium">{formatTL(p.contract_amount)}</Td>
                    <Td className="text-text-muted">{p.currency}</Td>
                    <Td className="text-right text-text-muted">{NO_DATA}</Td>
                    <Td className="text-right text-text-muted">{NO_DATA}</Td>
                    <Td className="text-right text-text-muted">{NO_DATA}</Td>
                    <Td className="text-right text-text-muted">{NO_DATA}</Td>
                    <Td className="text-text-muted">{NO_DATA}</Td>
                    <Td>
                      <Badge tone={STATUS_TONE[p.status]}>{PROJECT_STATUS_LABELS[p.status]}</Badge>
                    </Td>
                  </Tr>
                ))}
                {projects.length === 0 && (
                  <tr>
                    <Td colSpan={13} className="text-center text-text-muted">
                      Proje bulunamadı. Kabul edilmiş bir teklifi &quot;Projeye Dönüştür&quot; ile
                      projeye çevirebilirsiniz.
                    </Td>
                  </tr>
                )}
              </tbody>
            </Table>
          </div>
        </Card>

        <div className="flex items-center justify-between text-xs text-text-muted">
          <span>
            {total} proje
            {totalPages > 1 && ` · sayfa ${page}/${totalPages}`}
          </span>
          {totalPages > 1 && (
            <div className="flex gap-3">
              {page > 1 && (
                <Link href={pageHref(page - 1)} className="hover:text-gold">
                  ← Önceki
                </Link>
              )}
              {page < totalPages && (
                <Link href={pageHref(page + 1)} className="hover:text-gold">
                  Sonraki →
                </Link>
              )}
            </div>
          )}
        </div>

        <p className="text-xs text-text-muted">
          Tahsilat, masraf, kârlılık ve fatura kolonları sonraki fazlarda gerçek verilere
          bağlanacak.
        </p>
      </div>
    </>
  );
}

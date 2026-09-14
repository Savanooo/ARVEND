import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/Card";
import { Pagination } from "@/components/ui/Pagination";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiServer } from "@/lib/api";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import { PROJECT_STATUS } from "@/lib/status";
import type { Project } from "@/lib/types";

import { ProjectFilters } from "./ProjectFilters";

const PAGE_SIZE = 25;

const NO_DATA = "—";

// Fatura durumu, satır başına ayrı sorgu açmadan liste sorgusunda
// toplanan sayılardan türetilir.
function invoiceLabel(total?: number, paid?: number) {
  if (!total) return NO_DATA;
  if (paid && paid >= total) return `${paid}/${total} ödendi`;
  return `${paid ?? 0}/${total} ödendi`;
}

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
      <PageHeader title="Projeler" />
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
                  <Th className="text-right">Ek İşler</Th>
                  <Th className="text-right">Güncel Proje Bedeli</Th>
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
                    <Td className="text-right font-medium">
                      {formatMoney(p.contract_amount, p.currency)}
                    </Td>
                    <Td className="text-right text-text-muted">
                      {p.change_order_net ? formatSignedMoney(p.change_order_net, p.currency) : NO_DATA}
                    </Td>
                    <Td className="text-right font-medium text-gold">
                      {formatMoney(p.current_contract_value ?? p.contract_amount, p.currency)}
                    </Td>
                    <Td className="text-text-muted">{p.currency}</Td>
                    <Td className="text-right">{formatMoney(p.collected_amount ?? 0, p.currency)}</Td>
                    <Td className="text-right">
                      {/* Negatif bakiye gizlenmez: fazla tahsilat olarak gösterilir. */}
                      {(p.remaining_receivable ?? 0) < 0
                        ? `${formatMoney(-(p.remaining_receivable ?? 0), p.currency)} fazla`
                        : formatMoney(p.remaining_receivable ?? 0, p.currency)}
                    </Td>
                    <Td className="text-right">{formatMoney(p.realized_cost ?? 0, p.currency)}</Td>
                    <Td
                      className={`text-right font-medium ${(p.realized_gross_profit ?? 0) < 0 ? "text-danger" : ""}`}
                    >
                      {formatMoney(p.realized_gross_profit ?? 0, p.currency)}
                    </Td>
                    <Td className="text-text-muted">
                      {invoiceLabel(p.invoice_count, p.paid_invoice_count)}
                    </Td>
                    <Td>
                      <StatusBadge status={p.status} registry={PROJECT_STATUS} />
                    </Td>
                  </Tr>
                ))}
                {projects.length === 0 && (
                  <tr>
                    <Td colSpan={15} className="text-center text-text-muted">
                      Proje bulunamadı. Kabul edilmiş bir teklifi &quot;Projeye Dönüştür&quot; ile
                      projeye çevirebilirsiniz.
                    </Td>
                  </tr>
                )}
              </tbody>
            </Table>
          </div>
        </Card>

        <Pagination page={page} totalPages={totalPages} total={total} itemLabel="proje" hrefForPage={pageHref} />

        <p className="text-xs text-text-muted">
          Güncel Proje Bedeli, ana sözleşme + onaylı ek işler/eksiltmeler toplamıdır. Toplam
          Masraf ve Brüt Kâr, gerçekleşen maliyeti (masraflar + taşerona ödenen) esas alır;
          taşeronların kalan taahhüdü proje detayındaki &quot;Tahmini&quot; değerlerde gösterilir.
        </p>
      </div>
    </>
  );
}

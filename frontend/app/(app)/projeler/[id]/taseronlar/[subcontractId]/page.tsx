import Link from "next/link";
import { cookies } from "next/headers";
import { notFound } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { buttonClass } from "@/components/ui/styles";
import { apiServer, ApiError } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import {
  projectIsLocked,
  subcontractPermsFrom,
  subcontractsTabHref,
  type ProgressClaim,
  type SubcontractChangeOrder,
  type SubcontractDetail,
  type SubcontractPayment,
} from "@/lib/subcontracts";
import type { BudgetLine, OrganizationCostCode, WBSNode } from "@/lib/types";

import { loadProject, NoAccess } from "../data";
import { SubcontractDetailView } from "./SubcontractDetailView";

// Taşeron sözleşmesi detayı (mobil SubcontractDetailScreen + hakediş/
// değişiklik emri detay ekranlarının web karşılığı). Yol mobil ile aynıdır:
// /projeler/{id}/taseronlar/{sözleşme}; ?hakedis= / ?degisiklik= ilgili
// kaydı açık getirir (bildirim bağlantıları, lib/dashboard.ts).

function first(v: string | string[] | undefined): string | null {
  const s = Array.isArray(v) ? v[0] : v;
  return s ? s : null;
}

function settled<T>(r: PromiseSettledResult<T>): T | null {
  return r.status === "fulfilled" ? r.value : null;
}

export default async function TaseronSozlesmesiPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string; subcontractId: string }>;
  searchParams: Promise<{ hakedis?: string | string[]; degisiklik?: string | string[] }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.projects);
  const { id, subcontractId } = await params;
  const sp = await searchParams;
  const perms = subcontractPermsFrom(user.permissions);
  const cookieHeader = (await cookies()).toString();

  const project = await loadProject(id, cookieHeader);
  if (project === "forbidden") {
    return (
      <>
        <PageHeader title="Taşeron Sözleşmesi" />
        <NoAccess />
      </>
    );
  }
  const back = (
    <Link href={subcontractsTabHref(project.id)} className={buttonClass("secondary")}>
      Taşeronlara Dön
    </Link>
  );
  if (!perms.canRead) {
    return (
      <>
        <PageHeader title="Taşeron Sözleşmesi" action={back} />
        <NoAccess message="Taşeron sözleşmelerini görüntüleme yetkiniz yok." />
      </>
    );
  }

  const base = `/api/v1/projects/${project.id}`;
  const detail = await apiServer<SubcontractDetail>(`${base}/subcontracts/${subcontractId}`, cookieHeader).catch(
    (err: unknown) => {
      if (err instanceof ApiError && err.status === 404) notFound();
      return null;
    }
  );
  if (!detail) {
    return (
      <>
        <PageHeader title="Taşeron Sözleşmesi" action={back} />
        <NoAccess />
      </>
    );
  }

  // Her kaynak kendi iznine bağlı; izni olmayan için istek atılmaz (null ->
  // ilgili bölüm gizli). Değişiklik emirleri sözleşmenin okuma iznini paylaşır.
  const sc = detail.subcontract;
  const [changeOrdersR, claimsR, paymentsR, costCodesR, budgetLinesR, wbsR] = await Promise.allSettled([
    apiServer<{ subcontract_change_orders: SubcontractChangeOrder[] }>(
      `${base}/subcontracts/${sc.id}/change-orders`,
      cookieHeader
    ),
    perms.canReadClaims
      ? apiServer<{ progress_claims: ProgressClaim[] }>(`${base}/subcontracts/${sc.id}/progress-claims`, cookieHeader)
      : Promise.resolve(null),
    perms.canReadPayments
      ? apiServer<{ payments: SubcontractPayment[] }>(`${base}/subcontracts/${sc.id}/payments`, cookieHeader)
      : Promise.resolve(null),
    apiServer<{ cost_codes: OrganizationCostCode[] }>("/api/v1/organization/cost-codes", cookieHeader),
    apiServer<{ budget_lines: BudgetLine[] }>(`${base}/budget/lines`, cookieHeader),
    apiServer<{ wbs_nodes: WBSNode[] }>(`${base}/wbs`, cookieHeader),
  ]);

  const supplier = sc.supplier_name || sc.supplier_code || "";
  return (
    <>
      <PageHeader title={`${sc.subcontract_no}${supplier ? ` — ${supplier}` : ""}`} action={back} />
      <SubcontractDetailView
        project={project}
        detail={detail}
        changeOrders={settled(changeOrdersR)?.subcontract_change_orders ?? null}
        claims={settled(claimsR)?.progress_claims ?? null}
        payments={settled(paymentsR)?.payments ?? null}
        costCodes={settled(costCodesR)?.cost_codes ?? null}
        budgetLines={settled(budgetLinesR)?.budget_lines ?? null}
        wbsNodes={settled(wbsR)?.wbs_nodes ?? null}
        perms={perms}
        locked={projectIsLocked(project.status)}
        focusClaimId={first(sp.hakedis)}
        focusChangeOrderId={first(sp.degisiklik)}
      />
    </>
  );
}

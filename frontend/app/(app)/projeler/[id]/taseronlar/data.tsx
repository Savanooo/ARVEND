import { notFound } from "next/navigation";

import { apiServer, ApiError } from "@/lib/api";
import type { BudgetLine, OrganizationCostCode, Project, Supplier, WBSNode } from "@/lib/types";

// Taşeron sayfalarının (yeni / detay / düzenle) ortak sunucu verisi. Yalnızca
// Server Component'lerden çağrılır.

/**
 * Proje: 404 -> "Kayıt bulunamadı" (bayat bildirim bağlantısı), erişim yoksa
 * "forbidden" -- sayfa Next'in ham hata ekranı yerine temiz bir mesaj
 * gösterir (proje detayıyla aynı davranış).
 */
export async function loadProject(id: string, cookieHeader: string): Promise<Project | "forbidden"> {
  try {
    return await apiServer<Project>(`/api/v1/projects/${id}`, cookieHeader);
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) notFound();
    return "forbidden";
  }
}

function settled<T>(r: PromiseSettledResult<T>): T | null {
  return r.status === "fulfilled" ? r.value : null;
}

/**
 * Form seçicileri: tedarikçi (organization.suppliers.read), maliyet kodu
 * (organization.cost_codes.read), bütçe kalemi / WBS (projects.budget.read).
 * Her biri bağımsızdır; okunamayan null döner, form o seçiciyi gizler ya da
 * uyarı gösterir.
 */
export async function loadPickers(projectId: string, cookieHeader: string) {
  const [suppliersR, costCodesR, budgetLinesR, wbsR] = await Promise.allSettled([
    apiServer<{ suppliers: Supplier[] }>("/api/v1/organization/suppliers", cookieHeader),
    apiServer<{ cost_codes: OrganizationCostCode[] }>("/api/v1/organization/cost-codes", cookieHeader),
    apiServer<{ budget_lines: BudgetLine[] }>(`/api/v1/projects/${projectId}/budget/lines`, cookieHeader),
    apiServer<{ wbs_nodes: WBSNode[] }>(`/api/v1/projects/${projectId}/wbs`, cookieHeader),
  ]);
  return {
    suppliers: settled(suppliersR)?.suppliers ?? null,
    costCodes: settled(costCodesR)?.cost_codes ?? null,
    budgetLines: settled(budgetLinesR)?.budget_lines ?? null,
    wbsNodes: settled(wbsR)?.wbs_nodes ?? null,
  };
}

export function NoAccess({ message = "Bu sayfayı görüntüleme yetkiniz yok ya da kayıt bulunamadı." }: { message?: string }) {
  return (
    <div className="p-8">
      <div className="rounded-lg border border-border bg-surface p-6 text-sm text-text-muted">{message}</div>
    </div>
  );
}

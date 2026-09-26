import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import type { OrganizationCostCode } from "@/lib/types";

import { CostCodesManager } from "./CostCodesManager";

export default async function MaliyetKodlariPage() {
  await requirePagePermission(PAGE_PERMISSIONS.costCodes);
  const cookieHeader = (await cookies()).toString();
  const { cost_codes: costCodes } = await apiServer<{ cost_codes: OrganizationCostCode[] }>(
    "/api/v1/organization/cost-codes",
    cookieHeader
  );

  return (
    <>
      <PageHeader
        title="Maliyet Kodları"
        action={<span className="text-xs text-text-muted">{costCodes.length} kod</span>}
      />
      <div className="p-8">
        <CostCodesManager initialCostCodes={costCodes} />
      </div>
    </>
  );
}

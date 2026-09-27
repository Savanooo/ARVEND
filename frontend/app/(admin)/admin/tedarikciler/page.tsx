import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { Supplier } from "@/lib/types";

import { SuppliersManager } from "./SuppliersManager";

export default async function TedarikcilerPage() {
  const me = await requirePagePermission(PAGE_PERMISSIONS.suppliers);
  const cookieHeader = (await cookies()).toString();
  const { suppliers } = await apiServer<{ suppliers: Supplier[] }>("/api/v1/organization/suppliers", cookieHeader);
  // Liste organization.suppliers.read ile açılır; ekleme/düzenleme/arşivleme
  // uçları (router.go) ayrıca organization.suppliers.manage ister.
  const canManage = canAccess(me, "organization.suppliers.manage");

  return (
    <>
      <PageHeader
        title="Tedarikçiler"
        action={<span className="text-xs text-text-muted">{suppliers.length} tedarikçi</span>}
      />
      <div className="p-8">
        <SuppliersManager initialSuppliers={suppliers} canManage={canManage} />
      </div>
    </>
  );
}

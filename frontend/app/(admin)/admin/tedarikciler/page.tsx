import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Supplier } from "@/lib/types";

import { SuppliersManager } from "./SuppliersManager";

export default async function TedarikcilerPage() {
  const cookieHeader = (await cookies()).toString();
  const { suppliers } = await apiServer<{ suppliers: Supplier[] }>("/api/v1/organization/suppliers", cookieHeader);

  return (
    <>
      <PageHeader
        title="Tedarikçiler"
        action={<span className="text-xs text-text-muted">{suppliers.length} tedarikçi</span>}
      />
      <div className="p-8">
        <SuppliersManager initialSuppliers={suppliers} />
      </div>
    </>
  );
}

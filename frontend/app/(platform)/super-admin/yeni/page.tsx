import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Plan } from "@/lib/types";

import { NewOrganizationForm } from "./NewOrganizationForm";

export default async function YeniFirmaPage() {
  const cookieHeader = (await cookies()).toString();
  const { plans } = await apiServer<{ plans: Plan[] }>("/api/v1/platform/plans", cookieHeader);

  return (
    <>
      <PageHeader title="Yeni Firma" />
      <div className="p-8">
        <NewOrganizationForm plans={plans} />
      </div>
    </>
  );
}

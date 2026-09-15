import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { OnboardingState } from "@/lib/types";

import { FirmaAyarlariTabs } from "./FirmaAyarlariTabs";

export default async function FirmaAyarlariPage() {
  const cookieHeader = (await cookies()).toString();
  const state = await apiServer<OnboardingState>("/api/v1/organization/settings/", cookieHeader);

  return (
    <>
      <PageHeader title="Firma Ayarları" />
      <div className="max-w-2xl p-8">
        <FirmaAyarlariTabs initialState={state} />
      </div>
    </>
  );
}

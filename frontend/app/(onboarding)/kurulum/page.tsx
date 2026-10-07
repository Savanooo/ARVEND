import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { apiServer } from "@/lib/api";
import { getCurrentUser } from "@/lib/auth";
import type { OnboardingState } from "@/lib/types";

import { OnboardingWizard } from "./OnboardingWizard";
import { SetupPendingNotice } from "./SetupPendingNotice";

export default async function KurulumPage() {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (user.must_change_password) redirect("/sifre-belirle");
  if (user.role === "super_admin" || user.onboarding_completed) {
    redirect(user.role === "admin" ? "/admin" : user.role === "super_admin" ? "/super-admin" : "/panel");
  }

  // /onboarding uçları yalnızca Sahip/Yönetici'ye açık (requireAdmin):
  // diğer üyeler 403 alıp sayfayı çökertiyordu. Onlara bekleme bilgisi.
  if (user.role !== "admin") {
    return <SetupPendingNotice organizationName={user.organization_name} />;
  }

  const cookieHeader = (await cookies()).toString();
  const state = await apiServer<OnboardingState>("/api/v1/onboarding/", cookieHeader);

  return <OnboardingWizard initialState={state} />;
}

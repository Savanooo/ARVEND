import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { apiServer } from "@/lib/api";
import { getCurrentUser } from "@/lib/auth";
import type { OnboardingState } from "@/lib/types";

import { OnboardingWizard } from "./OnboardingWizard";

export default async function KurulumPage() {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (user.must_change_password) redirect("/sifre-belirle");
  if (user.role === "super_admin" || user.onboarding_completed) {
    redirect(user.role === "admin" ? "/admin" : user.role === "super_admin" ? "/super-admin" : "/panel");
  }

  const cookieHeader = (await cookies()).toString();
  const state = await apiServer<OnboardingState>("/api/v1/onboarding/", cookieHeader);

  return <OnboardingWizard initialState={state} />;
}

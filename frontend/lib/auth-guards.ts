import { redirect } from "next/navigation";

import { nextDestination, PLATFORM_HOME } from "./route-policy";
import type { User } from "./types";

// Karar mantığı lib/route-policy.ts'te (Next'siz, test edilebilir); bu
// dosya yalnızca Server Component'lerin kullandığı redirect sarmalayıcısı.
export { nextDestination };

/**
 * (admin)/(app)/(panel) layout'larının ortak zorunlu-akış kontrolü.
 * super_admin bu tenant kabuklarını ASLA render etmez -- ilgili layout'lar
 * zaten yönlendirir, burası ikinci bir emniyet katmanıdır.
 */
export function enforceFirstLoginFlow(user: User): void {
  if (user.role === "super_admin") redirect(PLATFORM_HOME);
  if (user.must_change_password) redirect("/sifre-belirle");
  if (!user.onboarding_completed) redirect("/kurulum");
}

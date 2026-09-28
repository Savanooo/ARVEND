import { cookies } from "next/headers";

import { apiServer } from "@/lib/api";
import { DASHBOARD_PATH, normalizeDashboard, type DashboardResponse } from "@/lib/dashboard";
import type { User } from "@/lib/types";

import { DashboardErrorBoundary } from "./DashboardErrorBoundary";
import { DashboardUnavailable } from "./DashboardUnavailable";
import { DashboardView } from "./DashboardView";

// Özeti TEK istekle çeker (GET /api/v1/dashboard; bölümler sunucuda kendi
// izinleriyle hesaplanır). ASLA fırlatmaz: istek ya da yanıt biçimi
// bozuksa "Özet yüklenemedi" + kısayollar gösterilir. (HANDOFF §7:
// akış içinde fırlatılan hata HTTP 200 ile RSC'ye gömülür ve sessizce
// sayfayı bozar -- bu yüzden loading.tsx yerine sayfa içi Suspense.)
// try/catch yalnızca isteği ve biçim kontrolünü kapsar; görünümün kendi
// render hatası (alt bileşenler sonradan çizilir) hata sınırına düşer.
export async function DashboardBody({ user }: { user: User }) {
  let data: DashboardResponse | null = null;
  try {
    const cookieHeader = (await cookies()).toString();
    data = normalizeDashboard(await apiServer<unknown>(DASHBOARD_PATH, cookieHeader));
  } catch {
    data = null;
  }
  if (!data) return <DashboardUnavailable user={user} />;
  return (
    <DashboardErrorBoundary key={data.generated_at} fallback={<DashboardUnavailable user={user} />}>
      <DashboardView data={data} user={user} />
    </DashboardErrorBoundary>
  );
}

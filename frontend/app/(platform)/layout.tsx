import { redirect } from "next/navigation";

import { PlatformShell } from "@/components/layout/PlatformShell";
import { getCurrentUser } from "@/lib/auth";
import { homeFor } from "@/lib/route-policy";

// SUPER ADMIN, organization Admin/Owner'dan KESİNLİKLE farklı bir platform
// rolüdür -- herhangi bir organizasyona bağlı değildir (organization_id
// null), bu yüzden must-change-password/onboarding kontrolü (tenant
// layout'larındaki enforceFirstLoginFlow) burada BİLİNÇLİ OLARAK yok ve
// tenant kabuğu (AppShell) yerine ayrı PlatformShell kullanılır.
export default async function PlatformLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  // proxy.ts JWT'yi doğrulamadan yönlendirir; asıl yetki kontrolü burada
  // (backend'e sorup gerçek rolü teyit ederek) ve her API çağrısında
  // backend'in RequireRole(super_admin) middleware'inde tekrar yapılır.
  if (!user) redirect("/giris");
  if (user.role !== "super_admin") redirect(homeFor(user.role));

  return <PlatformShell user={user}>{children}</PlatformShell>;
}

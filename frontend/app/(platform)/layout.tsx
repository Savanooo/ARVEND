import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/AppShell";
import { getCurrentUser } from "@/lib/auth";

// SUPER ADMIN, organization Admin/Owner'dan KESİNLİKLE farklı bir platform
// rolüdür -- herhangi bir organizasyona bağlı değildir (organization_id
// null), bu yüzden must-change-password/onboarding kontrolü (diğer üç
// layout'taki enforceFirstLoginFlow) burada BİLİNÇLİ OLARAK yok.
export default async function PlatformLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  // proxy.ts JWT'yi doğrulamadan yönlendirir; asıl yetki kontrolü burada
  // (backend'e sorup gerçek rolü teyit ederek) ve her API çağrısında
  // backend'in RequireRole middleware'inde tekrar yapılır.
  if (!user) redirect("/giris");
  if (user.role !== "super_admin") redirect(user.role === "admin" ? "/admin" : "/panel");

  return <AppShell user={user}>{children}</AppShell>;
}

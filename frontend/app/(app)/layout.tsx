import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/AppShell";
import { enforceFirstLoginFlow } from "@/lib/auth-guards";
import { getCurrentUser } from "@/lib/auth";

// Admin/panel ayrımına girmeyen, HER İKİ organization role'e de açık
// sayfalar için (şimdilik yalnız Teklifler). super_admin bu route'lara
// erişemez (route -- proxy.ts + üstteki role kontrolü yerine burada
// yönlendirme: super_admin'in organizasyonu yok, bu sayfalar org-scoped).
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (user.role === "super_admin") redirect("/super-admin");
  enforceFirstLoginFlow(user);

  return <AppShell user={user}>{children}</AppShell>;
}

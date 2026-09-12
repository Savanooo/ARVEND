import { redirect } from "next/navigation";

import { Sidebar } from "@/components/layout/Sidebar";
import { getCurrentUser } from "@/lib/auth";
import { getNavItems } from "@/lib/nav";

// Admin/panel ayrımına girmeyen, HER İKİ role de açık sayfalar için
// (şimdilik yalnız Teklifler). Rol şartı yok, sadece giriş kontrolü.
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");

  return (
    <div className="flex">
      <Sidebar user={user} items={getNavItems(user.role)} />
      <main className="flex-1">{children}</main>
    </div>
  );
}

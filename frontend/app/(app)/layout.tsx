import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/AppShell";
import { getCurrentUser } from "@/lib/auth";

// Admin/panel ayrımına girmeyen, HER İKİ role de açık sayfalar için
// (şimdilik yalnız Teklifler). Rol şartı yok, sadece giriş kontrolü.
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");

  return <AppShell user={user}>{children}</AppShell>;
}

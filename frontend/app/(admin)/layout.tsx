import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/AppShell";
import { getCurrentUser } from "@/lib/auth";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  // proxy.ts JWT'yi doğrulamadan yönlendirir; asıl yetki kontrolü burada
  // (backend'e sorup gerçek rolü teyit ederek) ve her API çağrısında
  // backend'in RequireRole middleware'inde tekrar yapılır.
  if (!user) redirect("/giris");
  if (user.role !== "admin") redirect("/panel");

  return <AppShell user={user}>{children}</AppShell>;
}

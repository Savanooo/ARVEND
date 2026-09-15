import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/AppShell";
import { enforceFirstLoginFlow } from "@/lib/auth-guards";
import { getCurrentUser } from "@/lib/auth";

export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (user.role === "super_admin") redirect("/super-admin");
  enforceFirstLoginFlow(user);

  return <AppShell user={user}>{children}</AppShell>;
}

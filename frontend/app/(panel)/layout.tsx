import { redirect } from "next/navigation";

import { Sidebar } from "@/components/layout/Sidebar";
import { getCurrentUser } from "@/lib/auth";
import { getNavItems } from "@/lib/nav";

export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");

  return (
    <div className="flex">
      <Sidebar user={user} items={getNavItems(user.role)} />
      <main className="flex-1">{children}</main>
    </div>
  );
}

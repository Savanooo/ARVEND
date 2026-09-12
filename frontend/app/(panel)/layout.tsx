import { redirect } from "next/navigation";

import { Sidebar } from "@/components/layout/Sidebar";
import { getCurrentUser } from "@/lib/auth";

const NAV_ITEMS = [
  { href: "/panel", label: "Ana Sayfa" },
  { href: "/panel/profil", label: "Profilim" },
];

export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");

  return (
    <div className="flex">
      <Sidebar user={user} items={NAV_ITEMS} />
      <main className="flex-1">{children}</main>
    </div>
  );
}

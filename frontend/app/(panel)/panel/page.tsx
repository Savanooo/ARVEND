import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { HomeDashboard } from "@/components/dashboard/HomeDashboard";
import { getCurrentUser } from "@/lib/auth";

export const metadata: Metadata = { title: "Ana Sayfa" };

// Sahip/Yönetici dışındaki üyelerin ana sayfası -- /admin ile aynı özet;
// hangi bölümlerin görüneceğine sunucu kişinin etkin izinlerine göre karar
// verir.
export default async function PanelAnaSayfaPage() {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  return <HomeDashboard user={user} />;
}

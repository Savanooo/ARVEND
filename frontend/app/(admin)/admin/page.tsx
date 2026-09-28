import type { Metadata } from "next";

import { HomeDashboard } from "@/components/dashboard/HomeDashboard";
import { requireAdminRole } from "@/lib/auth";

export const metadata: Metadata = { title: "Ana Sayfa" };

// Sahip/Yönetici ana sayfası (kaba rol admin). Diğer üyeler /panel'e
// yönlendirilir; ikisi de AYNI özeti gösterir, içerik izinlere göre sunucuda
// belirlenir (GET /api/v1/dashboard).
export default async function AdminAnaSayfaPage() {
  const user = await requireAdminRole();
  return <HomeDashboard user={user} />;
}

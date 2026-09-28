import { Suspense } from "react";

import type { User } from "@/lib/types";

import { DashboardBody } from "./DashboardBody";
import { DashboardHeader } from "./DashboardHeader";
import { DashboardSkeleton } from "./DashboardSkeleton";

// Ana sayfa ("bölüm bölüm özet") -- hem /admin (Sahip/Yönetici) hem
// /panel (diğer üyeler) aynı bileşeni kullanır; ne görüneceğine sunucu
// izinlere göre karar verir. Kök bir container'dır (@container/home):
// sidebar genişliği değiştiği için yerleşim görünüm alanına değil içerik
// genişliğine göre kademelenir. Başlık anında çizilir; özet sayfa içi
// Suspense ile akar (loading.tsx YOK, bkz. DashboardBody).
export function HomeDashboard({ user }: { user: User }) {
  return (
    <div className="@container/home">
      <DashboardHeader user={user} />
      <Suspense fallback={<DashboardSkeleton user={user} />}>
        <DashboardBody user={user} />
      </Suspense>
    </div>
  );
}

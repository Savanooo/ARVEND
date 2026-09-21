import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { ToastProvider } from "@/components/ui/Toast";
import { getPlatformNavItems } from "@/lib/nav";
import { homeFor } from "@/lib/route-policy";
import { SIDEBAR_COLLAPSED_COOKIE } from "@/lib/sidebar";
import type { User } from "@/lib/types";

import { Sidebar, type SidebarBrand } from "./Sidebar";
import { Topbar } from "./Topbar";

const PLATFORM_BRAND: SidebarBrand = { title: "ARVEND", subtitle: "Platform Yönetimi" };

// Süper Admin'in (platform hesabı) kabuğu -- tenant kabuğundan (AppShell)
// AYRI: menüde hiçbir firma-içi iş modülü (Teklifler/Projeler/Müşteriler/
// Mesai/...) yoktur, marka "firma" değil "platform" bağlamı taşır. Firma
// adı yalnızca bir firma KAYDI veri olarak gösterilirken (firma detayı)
// görünür. Yetki kontrolü (platform)/layout.tsx'te; buradaki koşul yalnızca
// bu kabuğun tenant hesabıyla ASLA render edilmemesi için ikinci emniyet.
export async function PlatformShell({ user, children }: { user: User; children: React.ReactNode }) {
  if (user.role !== "super_admin") redirect(homeFor(user.role));

  const cookieStore = await cookies();
  const collapsed = cookieStore.get(SIDEBAR_COLLAPSED_COOKIE)?.value === "1";

  return (
    <ToastProvider>
      <div className="flex min-h-screen">
        <Sidebar user={user} items={getPlatformNavItems()} collapsed={collapsed} brand={PLATFORM_BRAND} />
        <div className="flex min-w-0 flex-1 flex-col">
          <Topbar user={user} />
          {/* Platform içeriği geniş masaüstü ekranlarda sınırsız
              genişlemez -- profesyonel bir yönetim konsolu genişliğinde
              (1180-1360px) ortalanır; sayfaların kendi px-8/p-8
              boşlukları bu sütunun İÇİNDE değişmeden kalır, burada ek bir
              yatay boşluk EKLENMEZ (çift boşluk olmasın diye). Laptop/
              tablet genişliklerinde (viewport bu değerden darsa) mx-auto
              hiçbir şey yapmaz, içerik doğal olarak mevcut genişliği
              doldurur. */}
          <main className="mx-auto w-full max-w-[1320px] flex-1">{children}</main>
        </div>
      </div>
    </ToastProvider>
  );
}

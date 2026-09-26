import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { ToastProvider } from "@/components/ui/Toast";
import { getNavItems } from "@/lib/nav";
import { PLATFORM_HOME } from "@/lib/route-policy";
import { SIDEBAR_COLLAPSED_COOKIE } from "@/lib/sidebar";
import type { User } from "@/lib/types";

import { Sidebar } from "./Sidebar";
import { Topbar } from "./Topbar";

// TENANT (organizasyon) kabuğu -- (app)/(admin)/(panel) layout'larının
// ortak sidebar+içerik sarmalayıcısı. Auth/rol kontrolü ilgili layout
// dosyasında kalır; buradaki tek koşul, platform hesabının (super_admin)
// bu kabuğu HİÇBİR koşulda render etmemesi (kendi kabuğu: PlatformShell).
export async function AppShell({ user, children }: { user: User; children: React.ReactNode }) {
  if (user.role === "super_admin") redirect(PLATFORM_HOME);

  const cookieStore = await cookies();
  const collapsed = cookieStore.get(SIDEBAR_COLLAPSED_COOKIE)?.value === "1";

  return (
    <ToastProvider>
      <div className="flex min-h-screen">
        <Sidebar user={user} items={getNavItems(user.role, user.permissions)} collapsed={collapsed} />
        <div className="flex min-w-0 flex-1 flex-col">
          <Topbar user={user} />
          <main className="flex-1">{children}</main>
        </div>
      </div>
    </ToastProvider>
  );
}

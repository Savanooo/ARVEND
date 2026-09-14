import { cookies } from "next/headers";

import { ToastProvider } from "@/components/ui/Toast";
import { getNavItems } from "@/lib/nav";
import { SIDEBAR_COLLAPSED_COOKIE } from "@/lib/sidebar";
import type { User } from "@/lib/types";

import { Sidebar } from "./Sidebar";
import { Topbar } from "./Topbar";

// (app)/(admin)/(panel) layout'larının üçü de aynı sidebar+içerik
// sarmalayıcısını tekrarlıyordu -- auth/rol kontrolü SADECE ilgili
// layout dosyasında kalır (AppShell hiç auth mantığı taşımaz), bu
// sadece o üç dosyanın ortak, salt sunumsal kısmının çıkarılmış hali.
export async function AppShell({ user, children }: { user: User; children: React.ReactNode }) {
  const cookieStore = await cookies();
  const collapsed = cookieStore.get(SIDEBAR_COLLAPSED_COOKIE)?.value === "1";

  return (
    <ToastProvider>
      <div className="flex min-h-screen">
        <Sidebar user={user} items={getNavItems(user.role)} collapsed={collapsed} />
        <div className="flex min-w-0 flex-1 flex-col">
          <Topbar user={user} />
          <main className="flex-1">{children}</main>
        </div>
      </div>
    </ToastProvider>
  );
}

import type { User } from "@/lib/types";

import { LogoutButton } from "./LogoutButton";
import { Logo } from "./Logo";
import { NavLinks, type NavItem } from "./NavLinks";
import { SidebarCollapseToggle } from "./SidebarCollapseToggle";
import { Skyline } from "./Skyline";

export function Sidebar({
  user,
  items,
  collapsed = false,
}: {
  user: User;
  items: NavItem[];
  collapsed?: boolean;
}) {
  return (
    <aside
      className={`app-sidebar ${collapsed ? "app-sidebar-collapsed" : ""} relative flex h-screen shrink-0 flex-col justify-between overflow-hidden border-r border-sidebar-border bg-sidebar-bg text-sidebar-text`}
    >
      <div className={`relative z-10 flex flex-col gap-8 p-5 ${collapsed ? "items-center px-3" : ""}`}>
        <div className={`flex items-center gap-3 ${collapsed ? "flex-col gap-2" : ""}`}>
          <Logo />
          {!collapsed && (
            <div>
              <div className="text-sm font-bold uppercase tracking-widest">Arvend Yapı</div>
              <div className="text-[11px] text-sidebar-text-muted">Yönetim Sistemi</div>
            </div>
          )}
        </div>
        <NavLinks items={items} collapsed={collapsed} />
      </div>

      <div
        className={`relative z-10 flex flex-col gap-3 border-t border-sidebar-border p-5 ${collapsed ? "items-center px-3" : ""}`}
      >
        <div className={`flex items-center justify-between gap-2 ${collapsed ? "flex-col" : "w-full"}`}>
          {!collapsed && (
            <div className="min-w-0">
              <div className="truncate text-sm font-semibold">{user.full_name}</div>
              <div className="text-[11px] uppercase tracking-widest text-sidebar-text-muted">
                {user.role === "admin" ? "Yönetici" : "Kullanıcı"}
              </div>
            </div>
          )}
          <LogoutButton collapsed={collapsed} />
        </div>
        <SidebarCollapseToggle collapsed={collapsed} />
      </div>

      <Skyline />
    </aside>
  );
}

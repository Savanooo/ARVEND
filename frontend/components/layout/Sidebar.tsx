import type { User } from "@/lib/types";

import { LogoutButton } from "./LogoutButton";
import { Logo } from "./Logo";
import { NavLinks, type NavItem } from "./NavLinks";
import { Skyline } from "./Skyline";

export function Sidebar({ user, items }: { user: User; items: NavItem[] }) {
  return (
    <aside className="relative flex h-screen w-64 flex-col justify-between overflow-hidden border-r border-border bg-surface">
      <div className="relative z-10 flex flex-col gap-8 p-5">
        <div className="flex items-center gap-3">
          <Logo />
          <div>
            <div className="text-sm font-bold uppercase tracking-widest">
              Arvend Yapı
            </div>
            <div className="text-[11px] text-text-muted">Yönetim Sistemi</div>
          </div>
        </div>
        <NavLinks items={items} />
      </div>

      <div className="relative z-10 flex items-center justify-between border-t border-border p-5">
        <div>
          <div className="text-sm font-semibold">{user.full_name}</div>
          <div className="text-[11px] uppercase tracking-widest text-text-muted">
            {user.role === "admin" ? "Yönetici" : "Kullanıcı"}
          </div>
        </div>
        <LogoutButton />
      </div>

      <Skyline className="text-graphite" />
    </aside>
  );
}

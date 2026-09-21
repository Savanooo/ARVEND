import { Bell, Search } from "lucide-react";

import { PLATFORM_CONTEXT_LABEL, userRoleLabel, type User } from "@/lib/types";

// Uygulama kabuğunun (AppShell) üst çubuğu -- sayfaya özel PageHeader'dan
// farklı olarak her ekranda aynı kalır. Arama ve bildirim, backend'de
// henüz karşılığı olmadığı için BİLİNÇLİ OLARAK devre dışı/placeholder
// gösterilir -- çalışıyormuş gibi görünen ama hiçbir şey yapmayan bir
// giriş alanı yanıltıcı olurdu.
export function Topbar({ user }: { user: User }) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-border bg-surface px-6 py-3">
      <div className="relative w-full max-w-xs">
        <Search
          size={16}
          strokeWidth={1.75}
          className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-muted"
        />
        <input
          type="search"
          placeholder="Ara... (yakında)"
          disabled
          aria-disabled
          className="w-full rounded-md border border-border bg-surface-hover py-1.5 pl-9 pr-3 text-sm text-text-muted placeholder:text-text-muted/70 outline-none disabled:cursor-not-allowed"
        />
      </div>

      <div className="flex items-center gap-3">
        <button
          type="button"
          disabled
          aria-disabled
          title="Bildirimler (yakında)"
          className="rounded-md p-2 text-text-muted disabled:cursor-not-allowed disabled:opacity-60"
        >
          <Bell size={18} strokeWidth={1.75} />
        </button>
        <div className="flex items-center gap-2 border-l border-border pl-3">
          <div className="text-right">
            <div className="text-sm font-medium leading-tight">{user.full_name}</div>
            <div className="text-[11px] leading-tight text-text-muted">
              {userRoleLabel(user)}
              {user.role === "super_admin"
                ? ` · ${PLATFORM_CONTEXT_LABEL}`
                : user.organization_name && ` · ${user.organization_name}`}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

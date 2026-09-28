import { Bell, Search } from "lucide-react";

import { PLATFORM_CONTEXT_LABEL, userRoleLabel, type User } from "@/lib/types";

import { AppDownloadLink } from "./AppDownloadLink";

// Uygulama kabuğunun (AppShell) üst çubuğu -- sayfaya özel PageHeader'dan
// farklı olarak her ekranda aynı kalır. Arama ve bildirim, backend'de
// henüz karşılığı olmadığı için BİLİNÇLİ OLARAK devre dışı/placeholder
// gösterilir -- çalışıyormuş gibi görünen ama hiçbir şey yapmayan bir
// giriş alanı yanıltıcı olurdu.
export function Topbar({ user }: { user: User }) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-border bg-surface px-4 py-3 sm:px-6">
      {/* Arama henüz çalışmadığı için telefon genişliğinde hiç gösterilmez;
          yer açılınca ad tek satıra sığar. min-w-0: daralabilsin, sayfa yatay kaymasın. */}
      <div className="relative hidden w-full min-w-0 max-w-xs sm:block">
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
          className="w-full min-w-0 rounded-md border border-border bg-surface-hover py-1.5 pl-9 pr-3 text-sm text-text-muted placeholder:text-text-muted/70 outline-none disabled:cursor-not-allowed"
        />
      </div>

      <div className="ml-auto flex min-w-0 items-center gap-3">
        {/* İndirme ucu firma oturumu ister (requireTenant): Süper Admin'de yok. */}
        {user.role !== "super_admin" && <AppDownloadLink />}
        <button
          type="button"
          disabled
          aria-disabled
          title="Bildirimler (yakında)"
          className="rounded-md p-2 text-text-muted disabled:cursor-not-allowed disabled:opacity-60"
        >
          <Bell size={18} strokeWidth={1.75} />
        </button>
        <div className="flex min-w-0 items-center gap-2 border-l border-border pl-3">
          <div className="min-w-0 text-right">
            <div className="truncate text-sm font-medium leading-tight">{user.full_name}</div>
            {/* Rol · firma satırı telefonda gizli: dar ekranda ad 5 satıra bölünüyordu. */}
            <div className="hidden truncate text-[11px] leading-tight text-text-muted sm:block">
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

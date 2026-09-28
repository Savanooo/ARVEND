"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { NAV_ICONS } from "@/lib/nav-icons";

export interface NavItem {
  href: string;
  label: string;
}

// href -> ikon eşlemesi lib/nav-icons.ts'te (ana sayfanın Kısayollar
// ızgarası da kullanır). İkon bileşen referansları bir Server
// Component'ten prop olarak geçirilemediği için (bkz. lib/nav.ts) bu
// bileşen eşlemeyi kendisi içe aktarır.
export function NavLinks({ items, collapsed = false }: { items: NavItem[]; collapsed?: boolean }) {
  const pathname = usePathname();
  // En uzun eşleşen href aktif sayılır -- "/super-admin" ile
  // "/super-admin/planlar" (ya da "/admin" ile "/admin/urunler") aynı anda
  // vurgulanmasın.
  const activeHref = items.reduce<string | null>((best, item) => {
    const matches = pathname === item.href || pathname.startsWith(`${item.href}/`);
    if (!matches) return best;
    return best === null || item.href.length > best.length ? item.href : best;
  }, null);
  return (
    <nav className="flex flex-col gap-1">
      {items.map((item) => {
        const active = item.href === activeHref;
        const Icon = NAV_ICONS[item.href];
        return (
          // aria-label her zaman verilir: telefon genişliğinde (W0, bkz.
          // globals.css) menü daraltılmış çizilir ve etiket metni gizlenir.
          <Link
            key={item.href}
            href={item.href}
            aria-label={item.label}
            aria-current={active ? "page" : undefined}
            title={collapsed ? item.label : undefined}
            className={`sidebar-nav-link flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors ${
              active ? "sidebar-nav-link-active" : ""
            } ${collapsed ? "justify-center" : ""}`}
          >
            {Icon && <Icon size={18} strokeWidth={1.75} className="shrink-0" />}
            {!collapsed && <span className="sidebar-label">{item.label}</span>}
          </Link>
        );
      })}
    </nav>
  );
}

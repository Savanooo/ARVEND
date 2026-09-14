"use client";

import {
  Building2,
  CircleUserRound,
  Clock,
  FileText,
  HardHat,
  LayoutDashboard,
  type LucideIcon,
  Package,
  Settings,
  UserCog,
  Users,
} from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

export interface NavItem {
  href: string;
  label: string;
}

// href -> ikon eşlemesi BİLİNÇLİ OLARAK burada (client tarafında)
// tutulur -- bkz. lib/nav.ts'teki yorum: lucide ikon bileşen
// referansları bir Server Component'ten prop olarak geçirilemez.
const ICONS: Record<string, LucideIcon> = {
  "/admin": LayoutDashboard,
  "/panel": LayoutDashboard,
  "/teklifler": FileText,
  "/projeler": Building2,
  "/mesai": Clock,
  "/musteriler": Users,
  "/admin/urunler": Package,
  "/admin/personel": HardHat,
  "/admin/kullanicilar": UserCog,
  "/admin/ayarlar": Settings,
  "/panel/profil": CircleUserRound,
};

export function NavLinks({ items, collapsed = false }: { items: NavItem[]; collapsed?: boolean }) {
  const pathname = usePathname();
  return (
    <nav className="flex flex-col gap-1">
      {items.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        const Icon = ICONS[item.href];
        return (
          <Link
            key={item.href}
            href={item.href}
            title={collapsed ? item.label : undefined}
            className={`sidebar-nav-link flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors ${
              active ? "sidebar-nav-link-active" : ""
            } ${collapsed ? "justify-center" : ""}`}
          >
            {Icon && <Icon size={18} strokeWidth={1.75} className="shrink-0" />}
            {!collapsed && <span>{item.label}</span>}
          </Link>
        );
      })}
    </nav>
  );
}

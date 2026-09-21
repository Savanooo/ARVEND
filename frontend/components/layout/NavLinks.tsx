"use client";

import {
  Building2,
  CircleUserRound,
  Clock,
  Coins,
  FileText,
  HardHat,
  Layers,
  LayoutDashboard,
  type LucideIcon,
  Package,
  Ruler,
  Settings,
  ShieldCheck,
  Truck,
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
  "/super-admin": Building2,
  "/super-admin/planlar": Layers,
  "/teklifler": FileText,
  "/projeler": Building2,
  "/mesai": Clock,
  "/musteriler": Users,
  "/admin/urunler": Package,
  "/admin/metraj-hesaplama": Ruler,
  "/admin/personel": HardHat,
  "/admin/kullanicilar": UserCog,
  "/admin/roller": ShieldCheck,
  "/admin/maliyet-kodlari": Coins,
  "/admin/tedarikciler": Truck,
  "/admin/firma-ayarlari": Building2,
  "/admin/ayarlar": Settings,
  "/panel/profil": CircleUserRound,
};

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

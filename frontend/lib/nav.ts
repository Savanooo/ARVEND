import type { NavItem } from "@/components/layout/NavLinks";
import { canAccess, PAGE_PERMISSIONS } from "./permissions.ts";
import type { Role } from "./types";

// permission: o sayfanın ilk yüklemede çağırdığı liste ucunun backend'de
// zorladığı okuma izni (bkz. lib/permissions.ts). Boşsa öğe o kabukta HER
// ZAMAN görünür (ör. Ana Sayfa/Profilim, ya da backend'de yalnızca kaba
// requireAdmin ile korunan Firma Ayarları).
type GatedNavItem = NavItem & { permission?: string };

// Tek yerden yönetilir: hangi layout'ta (admin/panel/paylaşılan) olursa
// olsun sidebar aynı, role'e göre değişen nav listesini gösterir. "Özet"
// admin için "Ana Sayfa" ile aynı fikri taşıdığından aynı etiketle
// gösterilir -- route'lar (Mesai/Ürünler/Kullanıcılar dahil) DEĞİŞMEDİ.
// İkon eşlemesi BİLİNÇLİ OLARAK burada değil, lib/nav-icons.ts'te tutulur
// ve NavLinks.tsx (client) onu kendisi içe aktarır -- lucide ikon bileşen
// referansları bir Server Component'ten (bu dosyanın çağrıldığı yer) "use
// client" olan NavLinks'e prop olarak GEÇİRİLEMEZ (React Server Components
// ham fonksiyon referanslarının sınırı geçmesine izin vermez).
// Platform (super_admin) kabuğunun menüsü -- YALNIZCA backend'de karşılığı
// olan öğeler: Firmalar (/platform/organizations + lifecycle/plan/owner
// provisioning firma detayında), Planlar (GET /platform/plans, salt okunur
// -- plan CRUD ucu yok). Denetim kayıtları yalnızca firma bazlı bir uç
// olduğu için (/platform/organizations/{id}/audit-events) firma detayındaki
// sekmede kalır; "Platform Ayarları"/"Platform Kullanıcıları" için backend
// ucu YOKTUR, bu yüzden menüye EKLENMEDİ (sahte işlev üretilmez).
export function getPlatformNavItems(): NavItem[] {
  return [
    { href: "/super-admin", label: "Firmalar" },
    { href: "/super-admin/planlar", label: "Planlar" },
  ];
}

const ADMIN_ITEMS: GatedNavItem[] = [
  { href: "/admin", label: "Ana Sayfa" },
  { href: "/teklifler", label: "Teklifler", permission: PAGE_PERMISSIONS.offers },
  { href: "/projeler", label: "Projeler", permission: PAGE_PERMISSIONS.projects },
  { href: "/mesai", label: "Mesai & Maaş", permission: PAGE_PERMISSIONS.attendance },
  { href: "/musteriler", label: "Müşteriler", permission: PAGE_PERMISSIONS.customers },
  { href: "/admin/urunler", label: "Ürünler", permission: PAGE_PERMISSIONS.products },
  { href: "/admin/metraj-hesaplama", label: "Metraj Hesaplama", permission: PAGE_PERMISSIONS.calculations },
  { href: "/admin/personel", label: "Personel", permission: PAGE_PERMISSIONS.employees },
  { href: "/admin/kullanicilar", label: "Kullanıcılar", permission: PAGE_PERMISSIONS.users },
  { href: "/admin/roller", label: "Roller & Yetkiler", permission: PAGE_PERMISSIONS.roles },
  { href: "/admin/maliyet-kodlari", label: "Maliyet Kodları", permission: PAGE_PERMISSIONS.costCodes },
  { href: "/admin/tedarikciler", label: "Tedarikçiler", permission: PAGE_PERMISSIONS.suppliers },
  { href: "/admin/firma-ayarlari", label: "Firma Ayarları" },
  { href: "/admin/ayarlar", label: "Ayarlar", permission: PAGE_PERMISSIONS.smtpSettings },
];

// Yönetim bölümlerinden yalnızca izne bağlı olanlar (lib/route-policy.ts
// PERMISSION_GATED_ADMIN_PREFIXES) -- kişiye özel ya da rolden gelen izinle
// Sahip/Yönetici dışındaki üyeler de görür.
const PANEL_ITEMS: GatedNavItem[] = [
  { href: "/panel", label: "Ana Sayfa" },
  { href: "/teklifler", label: "Teklifler", permission: PAGE_PERMISSIONS.offers },
  { href: "/projeler", label: "Projeler", permission: PAGE_PERMISSIONS.projects },
  { href: "/mesai", label: "Mesai & Maaş", permission: PAGE_PERMISSIONS.attendance },
  { href: "/musteriler", label: "Müşteriler", permission: PAGE_PERMISSIONS.customers },
  { href: "/admin/urunler", label: "Ürünler", permission: PAGE_PERMISSIONS.products },
  { href: "/admin/metraj-hesaplama", label: "Metraj Hesaplama", permission: PAGE_PERMISSIONS.calculations },
  { href: "/admin/personel", label: "Personel", permission: PAGE_PERMISSIONS.employees },
  { href: "/admin/maliyet-kodlari", label: "Maliyet Kodları", permission: PAGE_PERMISSIONS.costCodes },
  { href: "/admin/tedarikciler", label: "Tedarikçiler", permission: PAGE_PERMISSIONS.suppliers },
  { href: "/panel/profil", label: "Profilim" },
];

// Menü, Roller & Yetkiler'deki rol izinleri ve kişiye özel ayarlarla
// oluşan etkin izin kümesine göre SÜZÜLÜR -- eskiden yalnızca kaba role
// (admin/kullanici) bakılıyordu, bu yüzden ör. Saha rolündeki bir üye
// "Teklifler"i görüp tıklayınca backend 403 döndüğü için sayfa çöküyordu.
export function getNavItems(role: Role, permissions: readonly string[] | undefined): NavItem[] {
  // super_admin, organization Admin/Owner'dan ayrı bir platform rolüdür --
  // herhangi bir organizasyona ait iş sayfasına (Teklifler/Projeler/...)
  // erişimi YOK; tenant kabuğu (AppShell) onu hiç render etmez, bu dal
  // yalnızca fonksiyonun Role üzerinde toplam kalması içindir.
  if (role === "super_admin") {
    return getPlatformNavItems();
  }
  const items = role === "admin" ? ADMIN_ITEMS : PANEL_ITEMS;
  return items
    .filter((item) => !item.permission || canAccess({ role, permissions }, item.permission))
    .map(({ href, label }) => ({ href, label }));
}

import type { NavItem } from "@/components/layout/NavLinks";
import type { Role } from "./types";

// Tek yerden yönetilir: hangi layout'ta (admin/panel/paylaşılan) olursa
// olsun sidebar aynı, role'e göre değişen nav listesini gösterir.
export function getNavItems(role: Role): NavItem[] {
  if (role === "admin") {
    return [
      { href: "/admin", label: "Özet" },
      { href: "/teklifler", label: "Teklifler" },
      { href: "/mesai", label: "Mesai" },
      { href: "/musteriler", label: "Müşteriler" },
      { href: "/admin/urunler", label: "Ürünler" },
      { href: "/admin/personel", label: "Personel" },
      { href: "/admin/kullanicilar", label: "Kullanıcılar" },
      { href: "/admin/ayarlar", label: "Ayarlar" },
    ];
  }
  return [
    { href: "/panel", label: "Ana Sayfa" },
    { href: "/teklifler", label: "Teklifler" },
    { href: "/mesai", label: "Mesai" },
    { href: "/musteriler", label: "Müşteriler" },
    { href: "/panel/profil", label: "Profilim" },
  ];
}

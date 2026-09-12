import type { NavItem } from "@/components/layout/NavLinks";
import type { Role } from "./types";

// Tek yerden yönetilir: hangi layout'ta (admin/panel/paylaşılan) olursa
// olsun sidebar aynı, role'e göre değişen nav listesini gösterir.
export function getNavItems(role: Role): NavItem[] {
  if (role === "admin") {
    return [
      { href: "/admin", label: "Özet" },
      { href: "/teklifler", label: "Teklifler" },
      { href: "/admin/urunler", label: "Ürünler" },
      { href: "/admin/kullanicilar", label: "Kullanıcılar" },
    ];
  }
  return [
    { href: "/panel", label: "Ana Sayfa" },
    { href: "/teklifler", label: "Teklifler" },
    { href: "/panel/profil", label: "Profilim" },
  ];
}

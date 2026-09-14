import type { NavItem } from "@/components/layout/NavLinks";
import type { Role } from "./types";

// Tek yerden yönetilir: hangi layout'ta (admin/panel/paylaşılan) olursa
// olsun sidebar aynı, role'e göre değişen nav listesini gösterir. "Özet"
// admin için "Ana Sayfa" ile aynı fikri taşıdığından aynı etiketle
// gösterilir -- route'lar (Mesai/Ürünler/Kullanıcılar dahil) DEĞİŞMEDİ.
// İkon eşlemesi BİLİNÇLİ OLARAK burada değil, NavLinks.tsx içinde
// (client tarafında) tutulur -- lucide ikon bileşen referansları bir
// Server Component'ten (bu dosyanın çağrıldığı yer) "use client" olan
// NavLinks'e prop olarak GEÇİRİLEMEZ (React Server Components ham
// fonksiyon referanslarının sınırı geçmesine izin vermez).
export function getNavItems(role: Role): NavItem[] {
  if (role === "admin") {
    return [
      { href: "/admin", label: "Ana Sayfa" },
      { href: "/teklifler", label: "Teklifler" },
      { href: "/projeler", label: "Projeler" },
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
    { href: "/projeler", label: "Projeler" },
    { href: "/mesai", label: "Mesai" },
    { href: "/musteriler", label: "Müşteriler" },
    { href: "/panel/profil", label: "Profilim" },
  ];
}

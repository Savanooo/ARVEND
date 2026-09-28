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

// Menü href -> ikon eşlemesi. Eskiden "use client" olan NavLinks.tsx'in
// içindeydi; ana sayfanın "Kısayollar" ızgarası (Server Component) da
// aynı ikonları kullandığı için ortak, "use client" OLMAYAN bu modüle
// taşındı. İkon bileşenleri yine prop olarak sunucu->istemci sınırından
// GEÇİRİLMEZ: her iki taraf da bu modülü kendisi içe aktarır.
export const NAV_ICONS: Record<string, LucideIcon> = {
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

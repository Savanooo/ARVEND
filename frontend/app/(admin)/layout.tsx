import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/AppShell";
import { enforceFirstLoginFlow } from "@/lib/auth-guards";
import { getCurrentUser } from "@/lib/auth";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  // proxy.ts JWT'yi doğrulamadan yönlendirir; asıl yetki kontrolü burada
  // (backend'e sorup gerçek rolü teyit ederek) ve her API çağrısında
  // backend'de tekrar yapılır. Kabuk kullanici hesaplarına da açıktır:
  // Ürünler/Personel gibi izne bağlı bölümlere izni olan her üye girer.
  // Her sayfa kendi kapısını çağırır -- requirePagePermission (izne bağlı
  // bölümler) ya da requireAdminRole (Özet, Firma Ayarları); Kullanıcılar/
  // Roller/Ayarlar'ın izinleri Yönetici'ye kilitli olduğundan
  // requirePagePermission kullanici'yi zaten geri gönderir.
  if (!user) redirect("/giris");
  if (user.role === "super_admin") redirect("/super-admin");
  enforceFirstLoginFlow(user);

  return <AppShell user={user}>{children}</AppShell>;
}

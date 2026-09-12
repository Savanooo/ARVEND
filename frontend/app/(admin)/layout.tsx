import { redirect } from "next/navigation";

import { Sidebar } from "@/components/layout/Sidebar";
import { getCurrentUser } from "@/lib/auth";

const NAV_ITEMS = [
  { href: "/admin", label: "Özet" },
  { href: "/admin/urunler", label: "Ürünler" },
  { href: "/admin/kullanicilar", label: "Kullanıcılar" },
];

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  // proxy.ts JWT'yi doğrulamadan yönlendirir; asıl yetki kontrolü burada
  // (backend'e sorup gerçek rolü teyit ederek) ve her API çağrısında
  // backend'in RequireRole middleware'inde tekrar yapılır.
  if (!user) redirect("/giris");
  if (user.role !== "admin") redirect("/panel");

  return (
    <div className="flex">
      <Sidebar user={user} items={NAV_ITEMS} />
      <main className="flex-1">{children}</main>
    </div>
  );
}

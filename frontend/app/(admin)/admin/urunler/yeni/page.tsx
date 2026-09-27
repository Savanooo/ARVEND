import { redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";

import { NewProductForm } from "./NewProductForm";

// Savunma katmanı: liste sayfası "+ Yeni Ürün"ü products.manage olmadan
// zaten göstermiyor (bkz. ../page.tsx), ama bu URL'e doğrudan girilebilir --
// izinsiz erişim listeye geri yönlendirilir, kullanıcı boş yere formu
// doldurup backend'den "yetkiniz yok" almaz.
export default async function YeniUrunPage() {
  const me = await requirePagePermission(PAGE_PERMISSIONS.products);
  if (!canAccess(me, "products.manage")) redirect("/admin/urunler");

  return (
    <>
      <PageHeader title="Yeni Ürün" />
      <div className="p-8">
        <NewProductForm />
      </div>
    </>
  );
}

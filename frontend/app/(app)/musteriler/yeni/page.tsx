import { redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { requirePagePermission } from "@/lib/auth";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";

import { NewCustomerForm } from "./NewCustomerForm";

// Savunma katmanı: liste sayfası "+ Yeni Müşteri"yi customers.manage
// olmadan zaten göstermiyor (bkz. ../page.tsx), ama bu URL'e doğrudan
// girilebilir -- izinsiz erişim listeye geri yönlendirilir, kullanıcı boş
// yere formu doldurup backend'den "yetkiniz yok" almaz.
export default async function YeniMusteriPage() {
  const user = await requirePagePermission(PAGE_PERMISSIONS.customers);
  if (!hasPermission(user.permissions, "customers.manage")) redirect("/musteriler");

  return (
    <>
      <PageHeader title="Yeni Müşteri" />
      <div className="p-8">
        <NewCustomerForm />
      </div>
    </>
  );
}

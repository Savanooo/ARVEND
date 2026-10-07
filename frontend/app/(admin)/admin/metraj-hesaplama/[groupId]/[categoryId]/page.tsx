import Link from "next/link";
import { notFound } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { canAccess, PAGE_PERMISSIONS } from "@/lib/permissions";
import { fetchAllProducts, type ProductPage } from "@/lib/products";
import type { CalcCategory, CalcGroup, CalcRecipeItem, Product } from "@/lib/types";

import { EditCategoryForm } from "./EditCategoryForm";
import { RecipeItemsEditor } from "./RecipeItemsEditor";

// Metraj uçlarını sayfa kapısı (calculations.read) garanti eder; ürün
// kataloğu ise AYRI bir izindir (products.read) -- kişiye özel yetkilerle
// "Metraj'ı görür ama ürünleri görmez" mümkün olduğundan yalnızca izin
// varsa çekilir, yoksa reçete ürün adları olmadan gösterilir.
async function fetchData(groupId: string, categoryId: string, canReadProducts: boolean) {
  const cookieHeader = (await cookies()).toString();
  const [{ groups }, { categories }, { items }, { products }] = await Promise.all([
    // include_inactive: pasif grup/kategori sayfası da açılır (yeniden
    // aktifleştirmek için) -- eskiden 404 veriyordu.
    apiServer<{ groups: CalcGroup[] }>("/api/v1/calculations/groups?include_inactive=1", cookieHeader),
    apiServer<{ categories: CalcCategory[] }>(
      `/api/v1/calculations/categories?group_id=${encodeURIComponent(groupId)}&include_inactive=1`,
      cookieHeader
    ),
    apiServer<{ items: CalcRecipeItem[] }>(
      `/api/v1/calculations/recipe-items?category_id=${categoryId}`,
      cookieHeader
    ),
    canReadProducts
      ? fetchAllProducts((path) => apiServer<ProductPage>(path, cookieHeader)).then((products) => ({ products }))
      : Promise.resolve({ products: [] as Product[] }),
  ]);
  const group = groups.find((g) => g.id === groupId);
  const category = categories.find((c) => c.id === categoryId);
  return { group, category, items, products };
}

export default async function CategoryDetailPage({
  params,
}: {
  params: Promise<{ groupId: string; categoryId: string }>;
}) {
  const me = await requirePagePermission(PAGE_PERMISSIONS.calculations);
  const { groupId, categoryId } = await params;
  const canReadProducts = canAccess(me, PAGE_PERMISSIONS.products);
  const { group, category, items, products } = await fetchData(groupId, categoryId, canReadProducts);
  if (!group || !category) notFound();
  const canManage = canAccess(me, "calculations.manage");

  return (
    <>
      <PageHeader
        title={
          <span>
            <Link href="/admin/metraj-hesaplama" className="text-text-muted hover:underline">
              Metraj Hesaplama
            </Link>{" "}
            /{" "}
            <Link href={`/admin/metraj-hesaplama/${group.id}`} className="text-text-muted hover:underline">
              {group.name}
            </Link>{" "}
            / {category.name}
          </span>
        }
      />
      <div className="flex flex-col gap-6 p-8">
        {(!category.is_active || !group.is_active) && (
          <p className="rounded-md border border-border bg-surface-hover p-3 text-sm text-text-muted">
            {!category.is_active
              ? "Bu hesaplama türü pasif: Metraj Hesapla panelinde görünmez."
              : "Bu hesaplama türünün grubu pasif: grup yeniden aktifleştirilene kadar Metraj Hesapla panelinde görünmez."}
          </p>
        )}
        <EditCategoryForm category={category} groupId={group.id} canManage={canManage} />
        <RecipeItemsEditor
          categoryId={category.id}
          items={items}
          products={products}
          canManage={canManage}
          canReadProducts={canReadProducts}
        />
      </div>
    </>
  );
}

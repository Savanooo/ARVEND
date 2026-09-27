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
    apiServer<{ groups: CalcGroup[] }>("/api/v1/calculations/groups", cookieHeader),
    apiServer<{ categories: CalcCategory[] }>(
      `/api/v1/calculations/categories?group_id=${groupId}`,
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

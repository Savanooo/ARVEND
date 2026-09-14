import Link from "next/link";
import { notFound } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { CalcCategory, CalcGroup, CalcRecipeItem, Product } from "@/lib/types";

import { EditCategoryForm } from "./EditCategoryForm";
import { RecipeItemsEditor } from "./RecipeItemsEditor";

async function fetchData(groupId: string, categoryId: string) {
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
    apiServer<{ products: Product[]; total: number }>("/api/v1/products?limit=2000", cookieHeader),
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
  const { groupId, categoryId } = await params;
  const { group, category, items, products } = await fetchData(groupId, categoryId);
  if (!group || !category) notFound();

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
        <EditCategoryForm category={category} groupId={group.id} />
        <RecipeItemsEditor categoryId={category.id} items={items} products={products} />
      </div>
    </>
  );
}

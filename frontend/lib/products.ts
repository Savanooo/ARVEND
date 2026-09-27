import type { Product } from "./types";

export type ProductPage = { products: Product[]; total: number };

// Backend (ProductService.List) sayfa başına en fazla 200 ürün döndürür;
// 200 üstü bir limit SESSİZCE 50'ye düşer. Teklif ve Metraj ekranlarındaki
// ürün seçicileri tüm kataloğa ihtiyaç duyar (Ulaş listesi tek başına ~630
// ürün) -- "?limit=2000" ile yalnızca alfabetik ilk 50 ürün geliyordu.
export const PRODUCT_PAGE_SIZE = 200;
const MAX_PAGES = 50;

/** Tüm ürün kataloğunu sayfa sayfa çeker: ilk sayfadan toplamı öğrenir, kalanları paralel ister. */
export async function fetchAllProducts(fetchPage: (path: string) => Promise<ProductPage>): Promise<Product[]> {
  const path = (page: number) => `/api/v1/products?limit=${PRODUCT_PAGE_SIZE}&page=${page}`;
  const first = await fetchPage(path(1));
  const pages = Math.min(Math.ceil(first.total / PRODUCT_PAGE_SIZE), MAX_PAGES);
  if (pages <= 1) return first.products;
  const rest = await Promise.all(
    Array.from({ length: pages - 1 }, (_, i) => fetchPage(path(i + 2)).then((r) => r.products))
  );
  return [...first.products, ...rest.flat()];
}

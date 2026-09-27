import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { fetchAllProducts, PRODUCT_PAGE_SIZE, type ProductPage } from "./products.ts";
import type { Product } from "./types.ts";

// Backend'in sayfalama davranışını taklit eder: limit ≤ 200, page 1'den başlar.
function fakeCatalog(total: number) {
  const all = Array.from({ length: total }, (_, i) => ({ id: `p${i}`, name: `Ürün ${i}` }) as Product);
  const requested: string[] = [];
  const fetchPage = async (path: string): Promise<ProductPage> => {
    requested.push(path);
    const url = new URL(path, "http://x");
    const limit = Number(url.searchParams.get("limit"));
    const page = Number(url.searchParams.get("page"));
    assert.ok(limit <= 200, "backend 200 üstü limiti 50'ye düşürür");
    return { products: all.slice((page - 1) * limit, page * limit), total };
  };
  return { fetchPage, requested };
}

describe("fetchAllProducts", () => {
  it("Ulaş boyutunda katalog (732): ilk 50 değil tüm ürünler, tekrarsız", async () => {
    const { fetchPage, requested } = fakeCatalog(732);
    const products = await fetchAllProducts(fetchPage);
    assert.equal(products.length, 732);
    assert.equal(new Set(products.map((p) => p.id)).size, 732);
    assert.equal(requested.length, Math.ceil(732 / PRODUCT_PAGE_SIZE));
  });

  it("tek sayfalık ve boş katalogda tek istek", async () => {
    for (const total of [0, 1, PRODUCT_PAGE_SIZE]) {
      const { fetchPage, requested } = fakeCatalog(total);
      assert.equal((await fetchAllProducts(fetchPage)).length, total);
      assert.equal(requested.length, 1, `${total} ürün`);
    }
  });
});

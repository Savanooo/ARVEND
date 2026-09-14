import Link from "next/link";
import { cookies } from "next/headers";

import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { Product } from "@/lib/types";

async function fetchProducts(q: string) {
  const cookieHeader = (await cookies()).toString();
  const qs = q ? `?q=${encodeURIComponent(q)}` : "";
  return apiServer<{ products: Product[]; total: number }>(
    `/api/v1/products${qs}`,
    cookieHeader
  );
}

export default async function UrunlerPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q = "" } = await searchParams;
  const { products, total } = await fetchProducts(q);

  return (
    <>
      <PageHeader
        title="Ürünler"
        action={
          <Link href="/admin/urunler/yeni">
            <Button>+ Yeni Ürün</Button>
          </Link>
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <form className="max-w-xs">
          <Input
            name="q"
            defaultValue={q}
            placeholder="Ürün adında ara…"
          />
        </form>
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Ürün</Th>
                <Th>Birim</Th>
                <Th>Kategori</Th>
                <Th className="text-right">Birim Fiyat</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {products.map((p) => (
                <Tr key={p.id}>
                  <Td className="font-medium">{p.name}</Td>
                  <Td className="text-text-muted">{p.unit}</Td>
                  <Td className="text-text-muted">{p.category || "—"}</Td>
                  <Td className="text-right font-medium">
                    {formatTL(p.unit_price)}
                  </Td>
                  <Td className="text-right">
                    <Link
                      href={`/admin/urunler/${p.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      Düzenle
                    </Link>
                  </Td>
                </Tr>
              ))}
              {products.length === 0 && (
                <tr>
                  <Td colSpan={5} className="text-center text-text-muted">
                    Ürün bulunamadı.
                  </Td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
        <p className="text-xs text-text-muted">{total} ürün</p>
      </div>
    </>
  );
}

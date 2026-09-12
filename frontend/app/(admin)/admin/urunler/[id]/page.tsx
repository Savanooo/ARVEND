import { cookies } from "next/headers";

import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { PriceHistoryEntry, Product } from "@/lib/types";

import { EditProductForm } from "./EditProductForm";

export default async function UrunDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const [product, historyRes] = await Promise.all([
    apiServer<Product>(`/api/v1/products/${id}`, cookieHeader),
    apiServer<{ history: PriceHistoryEntry[] }>(
      `/api/v1/products/${id}/price-history`,
      cookieHeader
    ),
  ]);

  return (
    <>
      <Topbar title={product.name} />
      <div className="flex max-w-md flex-col gap-6 p-8">
        <EditProductForm product={product} />

        {historyRes.history.length > 0 && (
          <Card>
            <CardHeader>Fiyat Geçmişi</CardHeader>
            <CardBody className="flex flex-col gap-2">
              {historyRes.history.map((h, i) => (
                <div
                  key={i}
                  className="flex justify-between text-sm text-text-muted"
                >
                  <span>
                    {new Date(h.changed_at).toLocaleDateString("tr-TR")}
                  </span>
                  <span>
                    {formatTL(h.old_price)} → {formatTL(h.new_price)}
                  </span>
                </div>
              ))}
            </CardBody>
          </Card>
        )}
      </div>
    </>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiClient, ApiError } from "@/lib/api";
import type { Product } from "@/lib/types";

export default function YeniUrunPage() {
  const router = useRouter();
  const [form, setForm] = useState({
    name: "",
    unit: "adet",
    unit_price: 0,
    description: "",
    category: "",
  });
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await apiClient<Product>("/api/v1/products", {
        method: "POST",
        body: JSON.stringify(form),
      });
      router.push("/admin/urunler");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <>
      <PageHeader title="Yeni Ürün" />
      <div className="p-8">
        <Card className="max-w-md">
          <CardBody>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              <Input
                label="Ürün Adı"
                required
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
              />
              <div className="grid grid-cols-2 gap-3">
                <Input
                  label="Birim"
                  required
                  value={form.unit}
                  onChange={(e) => setForm({ ...form, unit: e.target.value })}
                />
                <Input
                  label="Birim Fiyat"
                  type="number"
                  step="0.01"
                  min={0}
                  required
                  value={form.unit_price}
                  onChange={(e) =>
                    setForm({ ...form, unit_price: parseFloat(e.target.value) || 0 })
                  }
                />
              </div>
              <Input
                label="Kategori"
                value={form.category}
                onChange={(e) => setForm({ ...form, category: e.target.value })}
              />
              <Input
                label="Açıklama"
                value={form.description}
                onChange={(e) => setForm({ ...form, description: e.target.value })}
              />
              {error && <p className="text-xs text-danger">{error}</p>}
              <Button type="submit" disabled={loading}>
                {loading ? "Kaydediliyor…" : "Ürün Oluştur"}
              </Button>
            </form>
          </CardBody>
        </Card>
      </div>
    </>
  );
}

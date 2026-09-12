"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Topbar } from "@/components/layout/Topbar";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { Offer, Product } from "@/lib/types";

interface ItemRow {
  product_name: string;
  quantity: string;
  unit_price: string;
}

const emptyRow = (): ItemRow => ({ product_name: "", quantity: "1", unit_price: "0" });

export default function YeniTeklifPage() {
  const router = useRouter();
  const [products, setProducts] = useState<Product[]>([]);
  const [customer, setCustomer] = useState({
    customer_name: "",
    customer_phone: "",
    customer_email: "",
    customer_address: "",
    notes: "",
  });
  const [vatRate, setVatRate] = useState("20");
  const [items, setItems] = useState<ItemRow[]>([emptyRow()]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    apiClient<{ products: Product[]; total: number }>("/api/v1/products?limit=2000")
      .then((res) => setProducts(res.products))
      .catch(() => {});
  }, []);

  const priceByName = useMemo(() => {
    const map = new Map<string, number>();
    for (const p of products) map.set(p.name, p.unit_price);
    return map;
  }, [products]);

  function updateItem(index: number, patch: Partial<ItemRow>) {
    setItems((prev) => prev.map((row, i) => (i === index ? { ...row, ...patch } : row)));
  }

  function handleProductName(index: number, name: string) {
    const known = priceByName.get(name);
    updateItem(index, {
      product_name: name,
      ...(known !== undefined ? { unit_price: String(known) } : {}),
    });
  }

  const computedRows = items.map((row) => {
    const qty = parseFloat(row.quantity.replace(",", ".")) || 0;
    const price = parseFloat(row.unit_price.replace(",", ".")) || 0;
    return { ...row, lineTotal: qty * price };
  });
  const subtotal = computedRows.reduce((sum, r) => sum + r.lineTotal, 0);
  const vat = parseFloat(vatRate.replace(",", ".")) || 0;
  const vatAmount = (subtotal * vat) / 100;
  const grandTotal = subtotal + vatAmount;

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const payload = {
        ...customer,
        vat_rate: vat,
        items: items
          .filter((r) => r.product_name.trim() && parseFloat(r.quantity) > 0)
          .map((r) => ({
            product_name: r.product_name.trim(),
            quantity: parseFloat(r.quantity.replace(",", ".")) || 0,
            unit_price: parseFloat(r.unit_price.replace(",", ".")) || 0,
          })),
      };
      const offer = await apiClient<Offer>("/api/v1/offers", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      router.push(`/teklifler/${offer.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <>
      <Topbar title="Yeni Teklif" />
      <div className="flex flex-col gap-6 p-8 lg:flex-row">
        <form onSubmit={handleSubmit} className="flex flex-1 flex-col gap-6">
          <Card>
            <CardHeader>Müşteri</CardHeader>
            <CardBody className="grid grid-cols-2 gap-4">
              <div className="col-span-2">
                <Input
                  label="Müşteri Adı"
                  required
                  value={customer.customer_name}
                  onChange={(e) => setCustomer({ ...customer, customer_name: e.target.value })}
                />
              </div>
              <Input
                label="Telefon"
                value={customer.customer_phone}
                onChange={(e) => setCustomer({ ...customer, customer_phone: e.target.value })}
              />
              <Input
                label="E-posta"
                value={customer.customer_email}
                onChange={(e) => setCustomer({ ...customer, customer_email: e.target.value })}
              />
              <div className="col-span-2">
                <Input
                  label="Adres"
                  value={customer.customer_address}
                  onChange={(e) => setCustomer({ ...customer, customer_address: e.target.value })}
                />
              </div>
            </CardBody>
          </Card>

          <Card>
            <CardHeader>Kalemler</CardHeader>
            <CardBody className="flex flex-col gap-3">
              <datalist id="urun-listesi">
                {products.map((p) => (
                  <option key={p.id} value={p.name} />
                ))}
              </datalist>
              {items.map((row, i) => (
                <div key={i} className="grid grid-cols-12 items-end gap-2">
                  <div className="col-span-6">
                    <Input
                      label={i === 0 ? "Ürün / Hizmet" : undefined}
                      list="urun-listesi"
                      value={row.product_name}
                      onChange={(e) => handleProductName(i, e.target.value)}
                      placeholder="Ürün adı yazın veya seçin"
                    />
                  </div>
                  <div className="col-span-2">
                    <Input
                      label={i === 0 ? "Miktar" : undefined}
                      type="number"
                      step="0.01"
                      value={row.quantity}
                      onChange={(e) => updateItem(i, { quantity: e.target.value })}
                    />
                  </div>
                  <div className="col-span-2">
                    <Input
                      label={i === 0 ? "Birim Fiyat" : undefined}
                      type="number"
                      step="0.01"
                      value={row.unit_price}
                      onChange={(e) => updateItem(i, { unit_price: e.target.value })}
                    />
                  </div>
                  <div className="col-span-1 text-right text-sm font-medium">
                    {formatTL(computedRows[i].lineTotal)}
                  </div>
                  <div className="col-span-1 text-right">
                    <button
                      type="button"
                      onClick={() => setItems((prev) => prev.filter((_, idx) => idx !== i))}
                      className="text-text-muted hover:text-danger"
                      aria-label="Satırı kaldır"
                    >
                      ✕
                    </button>
                  </div>
                </div>
              ))}
              <Button
                type="button"
                variant="secondary"
                className="w-fit"
                onClick={() => setItems((prev) => [...prev, emptyRow()])}
              >
                + Kalem Ekle
              </Button>
            </CardBody>
          </Card>

          {error && <p className="text-sm text-danger">{error}</p>}
          <Button type="submit" disabled={loading} className="w-fit">
            {loading ? "Kaydediliyor…" : "Teklifi Oluştur"}
          </Button>
        </form>

        <Card className="h-fit w-full lg:w-72">
          <CardHeader>Özet</CardHeader>
          <CardBody className="flex flex-col gap-3">
            <div className="flex flex-col gap-1.5">
              <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
                KDV (%)
              </label>
              <input
                type="number"
                step="0.01"
                min={0}
                value={vatRate}
                onChange={(e) => setVatRate(e.target.value)}
                className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
              />
            </div>
            <div className="flex justify-between text-sm text-text-muted">
              <span>Ara Toplam</span>
              <span className="font-medium text-text">{formatTL(subtotal)}</span>
            </div>
            <div className="flex justify-between text-sm text-text-muted">
              <span>KDV Tutarı</span>
              <span className="font-medium text-text">{formatTL(vatAmount)}</span>
            </div>
            <div className="flex justify-between border-t border-border pt-3 text-base font-bold">
              <span>Genel Toplam</span>
              <span>{formatTL(grandTotal)}</span>
            </div>
          </CardBody>
        </Card>
      </div>
    </>
  );
}

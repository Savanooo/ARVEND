"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Product } from "@/lib/types";

/**
 * sourceLink: ürünün tedarikçi listesiyle (Ulaş, Demir Profil) bağı.
 *   - "linked": kaynak ürünü, son listede var (ya da henüz hiç senkron yok).
 *     Backend kaynak satırlarını (ad, birim) ile eşleştirdiğinden bu iki
 *     alan kilitlidir: değişirse bir sonraki güncelleme ürünü yeniden ekler,
 *     bu kayıt "listede yok" olarak kalıp fiyat almaz. Birim fiyat da
 *     kilitlidir: her güncelleme (gece senkronu dahil) fiyatı tedarikçi
 *     fiyatı + kâr oranından yeniden hesaplayıp elle girilen değerin
 *     ÜZERİNE yazar -- elle düzenleme uyarısız geri alınıyordu. Fiyat kâr
 *     oranıyla (Fiyat Kaynakları kartı) yönetilir.
 *   - "missing": kaynak ürünü ama son listede yok -- zaten eşleşmiyor; ad ve
 *     birim düzenlenebilir (ör. listedeki adla aynı yapıp yeniden bağlamak).
 *   - "none": elle eklenen ürün.
 * sourceName: kaynağın kısa adı ("Demir Profil"); "none"da "".
 */
export type ProductSourceLink = "none" | "linked" | "missing";

export function EditProductForm({
  product,
  canManage,
  sourceLink,
  sourceName,
}: {
  product: Product;
  canManage: boolean;
  sourceLink: ProductSourceLink;
  sourceName: string;
}) {
  const router = useRouter();
  const [form, setForm] = useState({
    name: product.name,
    unit: product.unit,
    unit_price: product.unit_price,
    description: product.description,
    category: product.category,
  });
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/products/${product.id}`, {
        method: "PUT",
        body: JSON.stringify(form),
      });
      setMessage("Kaydedildi.");
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  const readOnly = !canManage;
  const lockNameUnit = sourceLink === "linked";
  const lockPrice = sourceLink === "linked";

  return (
    <Card>
      <CardHeader>Ürün Bilgileri</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          {readOnly && (
            <p className="text-xs text-text-muted">
              Bu kaydı yalnızca görüntüleyebilirsin; düzenlemek için rolünde &quot;Ürün kataloğunu düzenleme&quot; izni
              olmalı.
            </p>
          )}
          <Input
            label="Ürün Adı"
            required
            disabled={readOnly || lockNameUnit}
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Birim"
              required
              disabled={readOnly || lockNameUnit}
              value={form.unit}
              onChange={(e) => setForm({ ...form, unit: e.target.value })}
            />
            <Input
              label="Birim Fiyat"
              type="number"
              step="0.01"
              min={0}
              required
              disabled={readOnly || lockPrice}
              value={form.unit_price}
              onChange={(e) =>
                setForm({ ...form, unit_price: parseFloat(e.target.value) || 0 })
              }
            />
          </div>
          {!readOnly && sourceLink === "linked" && (
            <p className="-mt-2 text-xs text-text-muted">
              Ad ve birim {sourceName} listesinden gelir ve ürünü listeyle eşleştirmek için kullanılır, bu yüzden
              değiştirilemez. Değişselerdi bir sonraki güncelleme {sourceName} ürününü yeni bir kayıt olarak
              ekler, bu kayıt da fiyat almazdı. Farklı adla satmak için elle yeni ürün ekleyin.
              <br />
              Birim fiyat, {sourceName} fiyatına kâr oranı uygulanarak hesaplanır ve her fiyat güncellemesinde
              (gece otomatik güncellemesi dahil) yeniden yazılır; elle girilen fiyat korunmazdı. Fiyatı
              değiştirmek için {sourceName} kâr oranını (genel ya da kategori bazında) ayarlayın.
            </p>
          )}
          {!readOnly && sourceLink === "missing" && (
            <p className="-mt-2 text-xs text-text-muted">
              Bu ürün son {sourceName} listesinde yok. Ad ve birim, {sourceName} listesindekiyle birebir aynı
              (büyük/küçük harf dahil) olursa bir sonraki güncellemede yeniden eşleşir; farklı olursa{" "}
              {sourceName} ürünü ayrı bir kayıt olarak eklenir.
            </p>
          )}
          <Input
            label="Kategori"
            disabled={readOnly}
            value={form.category}
            onChange={(e) => setForm({ ...form, category: e.target.value })}
          />
          <Input
            label="Açıklama"
            disabled={readOnly}
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          {message && <p className="text-xs text-text-muted">{message}</p>}
          {!readOnly && (
            <Button type="submit" disabled={saving}>
              {saving ? "Kaydediliyor…" : "Kaydet"}
            </Button>
          )}
        </form>
      </CardBody>
    </Card>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { Select } from "@/components/ui/Select";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiClient, ApiError } from "@/lib/api";
import type { CalcRecipeItem, CalcType, Product, RoundingType } from "@/lib/types";

const CALC_TYPE_LABELS: Record<CalcType, string> = {
  area_based: "Alan bazlı (m²)",
  perimeter_based: "Çevre bazlı (m)",
  fixed: "Sabit",
};

const ROUNDING_LABELS: Record<RoundingType, string> = {
  none: "Yok (ham değer)",
  ceil: "Yukarı yuvarla (tam sayı/paket)",
  round: "En yakına yuvarla (2 ondalık)",
};

const ITEM_STATUS = {
  active: { label: "Aktif", tone: "success" as const },
  inactive: { label: "Pasif", tone: "muted" as const },
};

interface FormState {
  product_id: string;
  material_name: string;
  unit: string;
  calculation_type: CalcType;
  quantity_per_m2: string;
  quantity_per_meter: string;
  fixed_quantity: string;
  waste_percent: string;
  rounding_type: RoundingType;
  min_quantity: string;
  package_size: string;
  reference_unit_price: string;
  group_name: string;
  sort_order: string;
  is_active: boolean;
  notes: string;
}

function itemToForm(item?: CalcRecipeItem): FormState {
  return {
    product_id: item?.product_id ?? "",
    material_name: item?.material_name ?? "",
    unit: item?.unit ?? "",
    calculation_type: item?.calculation_type ?? "area_based",
    quantity_per_m2: item?.quantity_per_m2 ?? "0",
    quantity_per_meter: item?.quantity_per_meter ?? "0",
    fixed_quantity: item?.fixed_quantity ?? "0",
    waste_percent: item?.waste_percent ?? "0",
    rounding_type: item?.rounding_type ?? "none",
    min_quantity: item?.min_quantity ?? "",
    package_size: item?.package_size ?? "",
    reference_unit_price: item?.reference_unit_price ?? "0",
    group_name: item?.group_name ?? "",
    sort_order: String(item?.sort_order ?? 0),
    is_active: item?.is_active ?? true,
    notes: item?.notes ?? "",
  };
}

// RecipeItemsEditor: bir kategorinin malzeme reçetesinin tam CRUD'u.
// Miktar/fiyat alanları BİLİNÇLİ OLARAK string tutulur (backend de
// string bekler, bkz. calc_handler.go) -- ondalık hassasiyet formda da
// float64'e hiç düşürülmez.
export function RecipeItemsEditor({
  categoryId,
  items,
  products,
  canManage,
  canReadProducts,
}: {
  categoryId: string;
  items: CalcRecipeItem[];
  products: Product[];
  // Yalnızca "calculations.read" ile reçete görülür ama eklenemez/
  // düzenlenemez/silinemez; kalem modalı salt okunur açılır.
  canManage: boolean;
  // Ürün kataloğunu göremeyen biri (products.read yok) ürün adlarını ve
  // seçiciyi görmez; mevcut ürün bağlantısı kaydederken olduğu gibi korunur.
  canReadProducts: boolean;
}) {
  const router = useRouter();
  const [editing, setEditing] = useState<CalcRecipeItem | "new" | null>(null);
  const [form, setForm] = useState<FormState>(itemToForm());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { confirm, dialog } = useConfirmDialog();
  const readOnly = !canManage;

  function openCreate() {
    setForm(itemToForm());
    setEditing("new");
    setError(null);
  }

  function openEdit(item: CalcRecipeItem) {
    setForm(itemToForm(item));
    setEditing(item);
    setError(null);
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError(null);
    const payload = {
      category_id: categoryId,
      product_id: form.product_id || null,
      material_name: form.material_name,
      unit: form.unit,
      calculation_type: form.calculation_type,
      quantity_per_m2: form.quantity_per_m2 || "0",
      quantity_per_meter: form.quantity_per_meter || "0",
      fixed_quantity: form.fixed_quantity || "0",
      waste_percent: form.waste_percent || "0",
      rounding_type: form.rounding_type,
      min_quantity: form.min_quantity || null,
      package_size: form.package_size || null,
      reference_unit_price: form.reference_unit_price || "0",
      group_name: form.group_name,
      sort_order: parseInt(form.sort_order, 10) || 0,
      is_active: form.is_active,
      notes: form.notes || null,
    };
    try {
      if (editing === "new") {
        await apiClient("/api/v1/calculations/recipe-items", {
          method: "POST",
          body: JSON.stringify(payload),
        });
      } else if (editing) {
        await apiClient(`/api/v1/calculations/recipe-items/${editing.id}`, {
          method: "PUT",
          body: JSON.stringify(payload),
        });
      }
      setEditing(null);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(item: CalcRecipeItem) {
    if (
      !(await confirm({
        title: "Reçete Kalemini Sil",
        message: `"${item.material_name}" kalemini silmek istediğinize emin misiniz? Bu geçmiş tekliflerdeki hesap sonuçlarını ETKİLEMEZ (o kalemler dondurulmuş bir kopya taşır).`,
        danger: true,
      }))
    )
      return;
    try {
      await apiClient(`/api/v1/calculations/recipe-items/${item.id}`, { method: "DELETE" });
      router.refresh();
    } catch (err) {
      alert(err instanceof ApiError ? err.message : "Bağlantı hatası");
    }
  }

  return (
    <Card>
      <CardHeader className="flex items-center justify-between">
        <span>Malzeme Reçetesi</span>
        {canManage && <Button onClick={openCreate}>+ Yeni Kalem</Button>}
      </CardHeader>
      <Table>
        <thead>
          <tr>
            <Th>Malzeme</Th>
            <Th>Birim</Th>
            <Th>Hesap Türü</Th>
            <Th className="text-right">Katsayı</Th>
            <Th className="text-right">Fire %</Th>
            <Th>Yuvarlama</Th>
            <Th>Ürün</Th>
            <Th>Durum</Th>
            <Th />
          </tr>
        </thead>
        <tbody>
          {items.map((item) => (
            <Tr key={item.id}>
              <Td className="font-medium">{item.material_name}</Td>
              <Td className="text-text-muted">{item.unit}</Td>
              <Td className="text-text-muted">{CALC_TYPE_LABELS[item.calculation_type]}</Td>
              <Td className="text-right">
                {item.calculation_type === "perimeter_based"
                  ? item.quantity_per_meter
                  : item.calculation_type === "fixed"
                    ? item.fixed_quantity
                    : item.quantity_per_m2}
              </Td>
              <Td className="text-right">{item.waste_percent}</Td>
              <Td className="text-text-muted">{ROUNDING_LABELS[item.rounding_type]}</Td>
              <Td className="text-text-muted">
                {!item.product_id
                  ? "Bağlı değil"
                  : canReadProducts
                    ? products.find((p) => p.id === item.product_id)?.name ?? "—"
                    : "Bağlı"}
              </Td>
              <Td>
                <StatusBadge status={item.is_active ? "active" : "inactive"} registry={ITEM_STATUS} />
              </Td>
              <Td className="text-right">
                <div className="flex justify-end gap-3">
                  <button
                    type="button"
                    onClick={() => openEdit(item)}
                    className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                  >
                    {canManage ? "Düzenle" : "Görüntüle"}
                  </button>
                  {canManage && (
                    <button
                      type="button"
                      onClick={() => handleDelete(item)}
                      className="text-xs font-semibold uppercase tracking-widest text-danger hover:underline"
                    >
                      Sil
                    </button>
                  )}
                </div>
              </Td>
            </Tr>
          ))}
          {items.length === 0 && (
            <tr>
              <Td colSpan={9} className="text-center text-text-muted">
                Bu kategoride henüz reçete kalemi yok.
              </Td>
            </tr>
          )}
        </tbody>
      </Table>

      <Modal
        open={editing !== null}
        onClose={() => setEditing(null)}
        title={editing === "new" ? "Yeni Reçete Kalemi" : readOnly ? "Reçete Kalemi" : "Reçete Kalemini Düzenle"}
        widthClassName="max-w-2xl"
      >
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          {readOnly && (
            <p className="text-xs text-text-muted">
              Bu kaydı yalnızca görüntüleyebilirsin; düzenlemek için rolünde &quot;Metraj kataloğunu düzenleme&quot; izni olmalı.
            </p>
          )}
          {/* disabled fieldset, içindeki TÜM alanları tek yerden kilitler. */}
          <fieldset disabled={readOnly} className="flex min-w-0 flex-col gap-4">
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Malzeme Adı"
                required
                value={form.material_name}
                onChange={(e) => setForm({ ...form, material_name: e.target.value })}
              />
              <Input
                label="Birim"
                required
                placeholder="ör. adet, m², paket"
                value={form.unit}
                onChange={(e) => setForm({ ...form, unit: e.target.value })}
              />
            </div>

            <Select
              label="Hesaplama Türü"
              value={form.calculation_type}
              onChange={(e) => setForm({ ...form, calculation_type: e.target.value as CalcType })}
            >
              {Object.entries(CALC_TYPE_LABELS).map(([k, label]) => (
                <option key={k} value={k}>
                  {label}
                </option>
              ))}
            </Select>

            <div className="grid grid-cols-3 gap-3">
              <Input
                label="Katsayı / m²"
                disabled={form.calculation_type !== "area_based"}
                value={form.quantity_per_m2}
                onChange={(e) => setForm({ ...form, quantity_per_m2: e.target.value })}
              />
              <Input
                label="Katsayı / m (çevre)"
                disabled={form.calculation_type !== "perimeter_based"}
                value={form.quantity_per_meter}
                onChange={(e) => setForm({ ...form, quantity_per_meter: e.target.value })}
              />
              <Input
                label="Sabit Miktar"
                disabled={form.calculation_type !== "fixed"}
                value={form.fixed_quantity}
                onChange={(e) => setForm({ ...form, fixed_quantity: e.target.value })}
              />
            </div>
            <p className="text-xs text-text-muted">
              Yalnızca seçili hesaplama türüne uyan katsayı kullanılır; miktar = {" "}
              {form.calculation_type === "area_based" && "etkin alan (m²) × Katsayı/m²"}
              {form.calculation_type === "perimeter_based" && "çevre (m) × Katsayı/m"}
              {form.calculation_type === "fixed" && "her zaman Sabit Miktar"}
              {" "}→ fire → minimum → paket/yuvarlama.
            </p>

            <div className="grid grid-cols-3 gap-3">
              <Input
                label="Fire (%)"
                value={form.waste_percent}
                onChange={(e) => setForm({ ...form, waste_percent: e.target.value })}
              />
              <Select
                label="Yuvarlama"
                value={form.rounding_type}
                onChange={(e) => setForm({ ...form, rounding_type: e.target.value as RoundingType })}
              >
                {Object.entries(ROUNDING_LABELS).map(([k, label]) => (
                  <option key={k} value={k}>
                    {label}
                  </option>
                ))}
              </Select>
              <Input
                label="Referans Fiyat (TL)"
                value={form.reference_unit_price}
                onChange={(e) => setForm({ ...form, reference_unit_price: e.target.value })}
              />
            </div>

            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Minimum Miktar (opsiyonel)"
                placeholder="boş bırakılabilir"
                value={form.min_quantity}
                onChange={(e) => setForm({ ...form, min_quantity: e.target.value })}
              />
              <Input
                label="Paket Büyüklüğü (opsiyonel)"
                placeholder="ör. 3.6 — 1 paket kaç birim kaplar"
                value={form.package_size}
                onChange={(e) => setForm({ ...form, package_size: e.target.value })}
              />
            </div>
            <p className="text-xs text-text-muted">
              Paket büyüklüğü verilirse yuvarlama kuralının YERİNE geçer: sonuç, ham miktarı karşılamak için
              gereken PAKET SAYISIDIR (birim genelde &quot;paket/rulo/torba&quot; olmalı).
            </p>

            {canReadProducts ? (
              <Select
                label="Ürün (fiyat buradan okunur; boş bırakılabilir)"
                value={form.product_id}
                onChange={(e) => setForm({ ...form, product_id: e.target.value })}
              >
                <option value="">Bağlı değil</option>
                {/* Bağlı ürün listede yoksa seçici sessizce "Bağlı değil" göstermesin. */}
                {form.product_id && !products.some((p) => p.id === form.product_id) && (
                  <option value={form.product_id}>Bağlı ürün (listede yok)</option>
                )}
                {products.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name} ({p.unit}, {p.unit_price.toLocaleString("tr-TR")} TL)
                  </option>
                ))}
              </Select>
            ) : (
              <p className="text-xs text-text-muted">
                Ürün bağlantısı: {form.product_id ? "bağlı" : "bağlı değil"}
                {readOnly
                  ? "."
                  : " (değiştirmek için rolünde \"Ürün kataloğunu görüntüleme\" izni olmalı; kaydederken mevcut bağlantı korunur)."}
              </p>
            )}

            <div className="grid grid-cols-3 gap-3">
              <Input
                label="Alt Başlık"
                placeholder="ör. Ana Malzemeler"
                value={form.group_name}
                onChange={(e) => setForm({ ...form, group_name: e.target.value })}
              />
              <Input
                label="Sıra"
                type="number"
                value={form.sort_order}
                onChange={(e) => setForm({ ...form, sort_order: e.target.value })}
              />
              {editing !== "new" && (
                <label className="flex items-end gap-2 pb-2 text-sm text-text">
                  <input
                    type="checkbox"
                    checked={form.is_active}
                    onChange={(e) => setForm({ ...form, is_active: e.target.checked })}
                  />
                  Aktif
                </label>
              )}
            </div>

            <Input label="Not" value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          </fieldset>

          {error && <p className="text-xs text-danger">{error}</p>}
          {!readOnly && (
            <Button type="submit" disabled={saving}>
              {saving ? "Kaydediliyor…" : "Kaydet"}
            </Button>
          )}
        </form>
      </Modal>
      {dialog}
    </Card>
  );
}

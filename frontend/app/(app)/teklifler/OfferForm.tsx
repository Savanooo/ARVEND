"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useState } from "react";

import { Trash2 } from "lucide-react";

import { MetrajHesaplaPanel, type MetrajOfferItemDraft } from "@/components/calc/MetrajHesaplaPanel";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { CalcSnapshot, Customer, Offer, Product } from "@/lib/types";

interface ItemRow {
  product_id: string | null;
  product_name: string;
  quantity: string;
  unit_price: string;
  // Metraj Hesaplama entegrasyonu — serbest/elle eklenen satırlarda hepsi
  // boş/null kalır.
  unit: string;
  section_label: string | null;
  calc_category_id: string | null;
  calc_snapshot: CalcSnapshot | null;
}

const emptyRow = (): ItemRow => ({
  product_id: null,
  product_name: "",
  quantity: "1",
  unit_price: "0",
  unit: "",
  section_label: null,
  calc_category_id: null,
  calc_snapshot: null,
});

function offerToRows(offer?: Offer): ItemRow[] {
  if (!offer?.items?.length) return [emptyRow()];
  return offer.items.map((it) => ({
    product_id: it.product_id,
    product_name: it.product_name,
    quantity: String(it.quantity),
    unit_price: String(it.unit_price),
    unit: it.unit ?? "",
    section_label: it.section_label ?? null,
    calc_category_id: it.calc_category_id ?? null,
    calc_snapshot: it.calc_snapshot ?? null,
  }));
}

function draftToRow(draft: MetrajOfferItemDraft): ItemRow {
  return {
    product_id: draft.product_id,
    product_name: draft.product_name,
    quantity: String(draft.quantity),
    unit_price: String(draft.unit_price),
    unit: draft.unit,
    section_label: draft.section_label,
    calc_category_id: draft.calc_category_id,
    calc_snapshot: draft.calc_snapshot,
  };
}

// Hem yeni teklif oluşturma hem taslak düzenleme için ortak form --
// müşteri seçimi datalist üzerinden: bilinen bir müşteri adı seçilirse
// customer_id o karta bağlanır ve iletişim bilgileri o karttan otomatik
// dolar (salt-okunur); tanınmayan bir ad yazılırsa serbest metin olarak
// kalır (customer_id null).
export function OfferForm({ offer }: { offer?: Offer }) {
  const router = useRouter();
  const isEdit = !!offer;
  const [products, setProducts] = useState<Product[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [customerId, setCustomerId] = useState<string | null>(offer?.customer_id ?? null);
  const [customer, setCustomer] = useState({
    customer_name: offer?.customer_name ?? "",
    customer_phone: offer?.customer_phone ?? "",
    customer_email: offer?.customer_email ?? "",
    customer_address: offer?.customer_address ?? "",
    notes: offer?.notes ?? "",
  });
  const [vatRate, setVatRate] = useState(String(offer?.vat_rate ?? 20));
  const [items, setItems] = useState<ItemRow[]>(offerToRows(offer));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [metrajOpen, setMetrajOpen] = useState(false);

  useEffect(() => {
    apiClient<{ products: Product[]; total: number }>("/api/v1/products?limit=2000")
      .then((res) => setProducts(res.products))
      .catch(() => {});
    apiClient<{ customers: Customer[] }>("/api/v1/customers?filter=aktif")
      .then((res) => setCustomers(res.customers))
      .catch(() => {});
  }, []);

  const customerByName = useMemo(() => {
    const map = new Map<string, Customer>();
    for (const c of customers) map.set(c.name, c);
    return map;
  }, [customers]);

  function handleCustomerName(name: string) {
    const match = customerByName.get(name);
    if (match) {
      setCustomerId(match.id);
      setCustomer({
        customer_name: match.name,
        customer_phone: match.phone,
        customer_email: match.email,
        customer_address: match.address,
        notes: customer.notes,
      });
    } else {
      setCustomerId(null);
      setCustomer((prev) => ({ ...prev, customer_name: name }));
    }
  }

  function updateItem(index: number, patch: Partial<ItemRow>) {
    setItems((prev) => prev.map((row, i) => (i === index ? { ...row, ...patch } : row)));
  }

  // Metraj Hesapla panelinden gelen satırlar: form hâlâ hiç dokunulmamış
  // tek bir boş satır taşıyorsa (yeni teklif akışının başlangıç durumu)
  // o satırın YERİNE geçilir; aksi halde mevcut satırların sonuna eklenir.
  function handleAddFromMetraj(drafts: MetrajOfferItemDraft[]) {
    const newRows = drafts.map(draftToRow);
    setItems((prev) => {
      const isSinglePristineRow = prev.length === 1 && !prev[0].product_name.trim();
      return isSinglePristineRow ? newRows : [...prev, ...newRows];
    });
  }

  function handleProductName(index: number, name: string) {
    const known = products.find((p) => p.name === name);
    updateItem(index, {
      product_name: name,
      product_id: known?.id ?? null,
      ...(known !== undefined ? { unit_price: String(known.unit_price) } : {}),
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
  const customerIsLinked = customerId !== null;

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const payload = {
        customer_id: customerId,
        ...customer,
        vat_rate: vat,
        items: items
          .filter((r) => r.product_name.trim() && parseFloat(r.quantity) > 0)
          .map((r) => ({
            product_id: r.product_id,
            product_name: r.product_name.trim(),
            quantity: parseFloat(r.quantity.replace(",", ".")) || 0,
            unit_price: parseFloat(r.unit_price.replace(",", ".")) || 0,
            unit: r.unit,
            section_label: r.section_label,
            calc_category_id: r.calc_category_id,
            calc_snapshot: r.calc_snapshot,
          })),
      };
      const saved = isEdit
        ? await apiClient<Offer>(`/api/v1/offers/${offer!.id}`, {
            method: "PUT",
            body: JSON.stringify(payload),
          })
        : await apiClient<Offer>("/api/v1/offers", {
            method: "POST",
            body: JSON.stringify(payload),
          });
      router.push(`/teklifler/${saved.id}`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <div className="flex flex-col gap-6 p-8 lg:flex-row">
      <form onSubmit={handleSubmit} className="flex flex-1 flex-col gap-6">
        <Card>
          <CardHeader className="flex items-center justify-between">
            <span>Müşteri</span>
            <Link href="/musteriler/yeni" className="text-gold hover:underline normal-case">
              + Yeni Müşteri
            </Link>
          </CardHeader>
          <CardBody className="grid grid-cols-2 gap-4">
            <datalist id="musteri-listesi">
              {customers.map((c) => (
                <option key={c.id} value={c.name} />
              ))}
            </datalist>
            <div className="col-span-2">
              <Input
                label="Müşteri Adı"
                list="musteri-listesi"
                required
                value={customer.customer_name}
                onChange={(e) => handleCustomerName(e.target.value)}
                placeholder="Kayıtlı müşteri seçin veya yeni ad yazın"
              />
              {customerIsLinked && (
                <p className="mt-1 text-xs text-text-muted">
                  Kayıtlı müşteri kartına bağlı — iletişim bilgileri o karttan alınır.
                </p>
              )}
            </div>
            <Input
              label="Telefon"
              value={customer.customer_phone}
              disabled={customerIsLinked}
              onChange={(e) => setCustomer({ ...customer, customer_phone: e.target.value })}
            />
            <Input
              label="E-posta"
              value={customer.customer_email}
              disabled={customerIsLinked}
              onChange={(e) => setCustomer({ ...customer, customer_email: e.target.value })}
            />
            <div className="col-span-2">
              <Input
                label="Adres"
                value={customer.customer_address}
                disabled={customerIsLinked}
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
                  {row.calc_snapshot && (
                    <p className="mt-1 text-xs text-text-muted">
                      Metraj Hesapla{row.section_label ? ` · ${row.section_label}` : ""}
                      {row.unit ? ` · ${row.unit}` : ""}
                    </p>
                  )}
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
                  <IconButton
                    label="Satırı kaldır"
                    variant="ghost"
                    onClick={() => setItems((prev) => prev.filter((_, idx) => idx !== i))}
                    className="hover:text-danger"
                  >
                    <Trash2 size={16} strokeWidth={1.75} />
                  </IconButton>
                </div>
              </div>
            ))}
            <div className="flex gap-2">
              <Button
                type="button"
                variant="secondary"
                className="w-fit"
                onClick={() => setItems((prev) => [...prev, emptyRow()])}
              >
                + Kalem Ekle
              </Button>
              <Button type="button" variant="secondary" className="w-fit" onClick={() => setMetrajOpen(true)}>
                Metraj Hesapla
              </Button>
            </div>
          </CardBody>
        </Card>

        <MetrajHesaplaPanel
          open={metrajOpen}
          onClose={() => setMetrajOpen(false)}
          onAddItems={handleAddFromMetraj}
        />

        {error && <p className="text-sm text-danger">{error}</p>}
        <Button type="submit" disabled={loading} className="w-fit">
          {loading ? "Kaydediliyor…" : isEdit ? "Değişiklikleri Kaydet" : "Teklifi Oluştur"}
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
  );
}

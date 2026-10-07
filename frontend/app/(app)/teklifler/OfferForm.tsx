"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useState } from "react";

import { Trash2 } from "lucide-react";

import { MetrajHesaplaPanel, type MetrajOfferItemDraft } from "@/components/calc/MetrajHesaplaPanel";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { DateInput } from "@/components/ui/DateInput";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import { fetchAllProducts, type ProductPage } from "@/lib/products";
import type { CalcSnapshot, Customer, Offer, OfferItemPricingMode, Product } from "@/lib/types";

import { CustomerCreateForm } from "../musteriler/yeni/NewCustomerForm";

interface ItemRow {
  // Düzenlenen taslakta satırın karşılık geldiği mevcut kalemin id'si (yeni
  // satırlarda null). Backend, iç fiyatlama yetkisi olmayan düzenleyicinin
  // kaydında mevcut kalemlerin iç maliyetini bu id ile taşır -- id
  // gönderilmezse o maliyetleri silmemek için kaydı reddeder.
  id: string | null;
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
  // İç Taşeron Fiyatlama — MÜŞTERİYE ASLA gönderilmez (yalnızca
  // canManageInternalPricing true iken form alanları gösterilir/gönderilir;
  // backend YİNE DE offers.internal_pricing.manage izni yoksa bunları
  // sessizce temizler, bkz. computeOfferTotals). internal_cost boşsa
  // ("") bu kaleme iç fiyatlama uygulanmamış demektir.
  internal_cost: string;
  pricing_mode: OfferItemPricingMode;
  markup_percent: string;
}

const emptyRow = (): ItemRow => ({
  id: null,
  product_id: null,
  product_name: "",
  quantity: "1",
  unit_price: "0",
  unit: "",
  section_label: null,
  calc_category_id: null,
  calc_snapshot: null,
  internal_cost: "",
  pricing_mode: "manual",
  markup_percent: "",
});

function offerToRows(offer?: Offer): ItemRow[] {
  if (!offer?.items?.length) return [emptyRow()];
  return offer.items.map((it) => ({
    id: it.id,
    product_id: it.product_id,
    product_name: it.product_name,
    quantity: String(it.quantity),
    unit_price: String(it.unit_price),
    unit: it.unit ?? "",
    section_label: it.section_label ?? null,
    calc_category_id: it.calc_category_id ?? null,
    calc_snapshot: it.calc_snapshot ?? null,
    internal_cost: it.internal_pricing ? String(it.internal_pricing.cost) : "",
    pricing_mode: it.internal_pricing?.pricing_mode ?? "manual",
    markup_percent:
      it.internal_pricing?.markup_percent != null ? String(it.internal_pricing.markup_percent) : "",
  }));
}

function draftToRow(draft: MetrajOfferItemDraft): ItemRow {
  return {
    id: null,
    product_id: draft.product_id,
    product_name: draft.product_name,
    quantity: String(draft.quantity),
    unit_price: String(draft.unit_price),
    unit: draft.unit,
    section_label: draft.section_label,
    calc_category_id: draft.calc_category_id,
    calc_snapshot: draft.calc_snapshot,
    internal_cost: "",
    pricing_mode: "manual",
    markup_percent: "",
  };
}

function parseNum(raw: string): number {
  return parseFloat(raw.replace(",", ".")) || 0;
}

// Önizleme, sunucunun hesabıyla (computeOfferTotals) aynı sırayı izler:
// miktar ve birim fiyat önce 2 haneye yuvarlanır, satır toplamı onların
// çarpımıdır -- kaydettikten sonra tutarlar kuruşu kuruşuna aynı kalır.
function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

function todayISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// Hem yeni teklif oluşturma hem taslak düzenleme için ortak form.
// Müşteri seçimi KİMLİK ile yapılır: ad alanına yazarken kayıtlı
// müşteriler (ad, telefon, vergi no, e-postada) eşleşen öneriler olarak
// listelenir, birine tıklanınca customer_id o karta bağlanır ve iletişim
// bilgileri o karttan dolar (salt-okunur). Eskiden datalist ADI kartla
// eşliyordu -- aynı adlı iki müşteriden yalnızca biri seçilebiliyordu.
// Öneri seçilmezse ad serbest metin kalır (customer_id null).
export function OfferForm({
  offer,
  canManageInternalPricing = false,
  canReadCustomers = true,
  canManageCustomers = false,
  canReadProducts = true,
}: {
  offer?: Offer;
  // Yalnızca UX: izin yoksa ilgili liste hiç istenmez (403 hatası
  // gösterilmez), "+ Yeni Müşteri" yalnızca customers.manage ile görünür.
  canReadCustomers?: boolean;
  canManageCustomers?: boolean;
  canReadProducts?: boolean;
  // Sunucu bileşeninden (bkz. yeni/duzenle page.tsx) hesaplanıp geçirilir --
  // offers.internal_pricing.manage izni yoksa İç Fiyatlama bölümü hiç
  // RENDER EDİLMEZ (ekstra bir istemci-taraflı izin kontrolü değil, tek
  // kaynak backend'deki AuthzContext'tir; bu yalnızca UX'tir -- gerçek
  // sınır backend'de: izinsiz gönderilen alanlar sessizce temizlenir).
  canManageInternalPricing?: boolean;
}) {
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
  // Geçerlilik tarihi: boş = süresiz. Kaydederken HER ZAMAN gönderilir
  // ("" = temizle); backend, alanı hiç göndermeyen istemcilerde (mobil)
  // mevcut tarihi korur.
  const [validUntil, setValidUntil] = useState(offer?.valid_until ?? "");
  const [items, setItems] = useState<ItemRow[]>(offerToRows(offer));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [metrajOpen, setMetrajOpen] = useState(false);
  const [newCustomerOpen, setNewCustomerOpen] = useState(false);
  const [suggestOpen, setSuggestOpen] = useState(false);
  // Ürün/müşteri listesi yüklenemezse bunu söyleriz -- eskiden hata
  // yutuluyordu ve kullanıcı boş öneri listesini "kayıt yok" sanıyordu.
  const [loadErrors, setLoadErrors] = useState<string[]>([]);

  useEffect(() => {
    const fail = (what: string) => (err: unknown) => {
      const detail = err instanceof ApiError ? err.message : "bağlantı hatası";
      setLoadErrors((prev) => [...prev, `${what} yüklenemedi (${detail}). Sayfayı yenileyip tekrar deneyin.`]);
    };
    if (canReadProducts) {
      fetchAllProducts((path) => apiClient<ProductPage>(path))
        .then(setProducts)
        .catch(fail("Ürün listesi"));
    }
    if (canReadCustomers) {
      apiClient<{ customers: Customer[] }>("/api/v1/customers?filter=aktif")
        .then((res) => setCustomers(res.customers))
        .catch(fail("Müşteri listesi"));
    }
  }, [canReadCustomers, canReadProducts]);

  // Ad alanındaki metnin eşleştiği kayıtlı müşteriler (ad, telefon
  // rakamları, vergi no, e-posta) -- en çok 8 öneri.
  const customerSuggestions = useMemo(() => {
    const q = customer.customer_name.trim().toLocaleLowerCase("tr-TR");
    if (!q || customerId) return [];
    const digits = q.replace(/\D/g, "").replace(/^0+/, "");
    return customers
      .filter((c) => {
        const hay = `${c.name} ${c.tax_number} ${c.email}`.toLocaleLowerCase("tr-TR");
        if (hay.includes(q)) return true;
        return digits.length >= 3 && c.phone.replace(/\D/g, "").includes(digits);
      })
      .slice(0, 8);
  }, [customers, customer.customer_name, customerId]);

  function selectCustomer(match: Customer) {
    setCustomerId(match.id);
    setSuggestOpen(false);
    setCustomer((prev) => ({
      customer_name: match.name,
      customer_phone: match.phone,
      customer_email: match.email,
      customer_address: match.address,
      notes: prev.notes,
    }));
  }

  // Bağlı bir müşterinin adı elle değiştirilirse bağlantı kaldırılır --
  // ad artık o kartı göstermiyor; iletişim bilgileri düzenlenebilir kalır.
  function handleCustomerName(name: string) {
    setCustomerId(null);
    setSuggestOpen(true);
    setCustomer((prev) => ({ ...prev, customer_name: name }));
  }

  function handleCustomerCreated(created: Customer) {
    setCustomers((prev) => [...prev.filter((c) => c.id !== created.id), created]);
    selectCustomer(created);
    setNewCustomerOpen(false);
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

  // effectiveUnitPrice: markup modunda satış fiyatı maliyet*(1+markup/100)
  // İSTEMCİDE de aynı formülle ÖNİZLENİR (kaydederken sunucu ZATEN aynı
  // hesabı otoriter olarak tekrarlar, bkz. computeOfferTotals) -- manuel
  // modda ya da iç fiyatlama uygulanmayan kalemlerde her zaman kullanıcının
  // yazdığı unit_price'tır, hiç dokunulmaz.
  function effectiveUnitPrice(row: ItemRow): number {
    if (canManageInternalPricing && row.pricing_mode === "markup" && row.internal_cost.trim()) {
      const cost = round2(parseNum(row.internal_cost));
      const markup = round2(parseNum(row.markup_percent));
      return round2(cost * (1 + markup / 100));
    }
    return round2(parseNum(row.unit_price));
  }

  const computedRows = items.map((row) => {
    const qty = round2(parseNum(row.quantity));
    const price = effectiveUnitPrice(row);
    const cost = row.internal_cost.trim() ? parseNum(row.internal_cost) : null;
    return {
      ...row,
      lineTotal: round2(qty * price),
      effectivePrice: price,
      expectedProfit: cost !== null ? price - cost : null,
    };
  });
  const subtotal = round2(computedRows.reduce((sum, r) => sum + r.lineTotal, 0));
  const vat = parseFloat(vatRate.replace(",", ".")) || 0;
  const vatAmount = round2((subtotal * vat) / 100);
  const grandTotal = round2(subtotal + vatAmount);
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
        valid_until: validUntil,
        items: items
          .filter((r) => r.product_name.trim() && parseFloat(r.quantity) > 0)
          .map((r) => ({
            id: r.id,
            product_id: r.product_id,
            product_name: r.product_name.trim(),
            quantity: parseNum(r.quantity),
            unit_price: effectiveUnitPrice(r),
            unit: r.unit,
            section_label: r.section_label,
            calc_category_id: r.calc_category_id,
            calc_snapshot: r.calc_snapshot,
            // İç Taşeron Fiyatlama — yalnızca bölüm görünürken (izin
            // varken) VE kullanıcı bir maliyet girmişken gönderilir; sunucu
            // izinsizse bunları YİNE DE sessizce temizler (tek gerçek
            // sınır orada), burası yalnızca gereksiz alan göndermemek için.
            ...(canManageInternalPricing && r.internal_cost.trim()
              ? {
                  internal_subcontract_cost: parseNum(r.internal_cost),
                  pricing_mode: r.pricing_mode,
                  markup_percent: r.pricing_mode === "markup" ? parseNum(r.markup_percent) : null,
                }
              : {}),
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
        {loadErrors.length > 0 && (
          <div role="alert" className="rounded-md border border-danger/40 bg-danger-soft p-3 text-sm text-danger">
            {loadErrors.map((m) => (
              <p key={m}>{m}</p>
            ))}
          </div>
        )}
        <Card>
          <CardHeader className="flex items-center justify-between">
            <span>Müşteri</span>
            {canManageCustomers && (
              <button
                type="button"
                onClick={() => setNewCustomerOpen(true)}
                className="text-gold hover:underline normal-case"
              >
                + Yeni Müşteri
              </button>
            )}
          </CardHeader>
          <CardBody className="grid grid-cols-2 gap-4">
            <div className="relative col-span-2">
              <Input
                label="Müşteri Adı"
                required
                autoComplete="off"
                value={customer.customer_name}
                onChange={(e) => handleCustomerName(e.target.value)}
                onFocus={() => setSuggestOpen(true)}
                onBlur={() => setTimeout(() => setSuggestOpen(false), 150)}
                placeholder="Kayıtlı müşteri arayın (ad, telefon, vergi no) veya yeni ad yazın"
              />
              {suggestOpen && customerSuggestions.length > 0 && (
                <ul
                  role="listbox"
                  className="absolute left-0 right-0 z-20 mt-1 max-h-64 overflow-y-auto rounded-md border border-border bg-surface shadow-lg"
                >
                  {customerSuggestions.map((c) => (
                    <li key={c.id}>
                      <button
                        type="button"
                        role="option"
                        aria-selected={false}
                        // onMouseDown: input blur olmadan seçim yapılsın.
                        onMouseDown={(e) => {
                          e.preventDefault();
                          selectCustomer(c);
                        }}
                        className="flex w-full flex-col items-start px-3 py-2 text-left text-sm hover:bg-surface-hover"
                      >
                        <span className="font-medium">{c.name}</span>
                        <span className="text-xs text-text-muted">
                          {[c.phone, c.tax_number && `VKN ${c.tax_number}`, c.email].filter(Boolean).join(" · ") ||
                            "İletişim bilgisi yok"}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {customerIsLinked && (
                <p className="mt-1 text-xs text-text-muted">
                  Kayıtlı müşteri kartına bağlı — iletişim bilgileri o karttan alınır.{" "}
                  <button type="button" className="text-gold hover:underline" onClick={() => setCustomerId(null)}>
                    Bağlantıyı kaldır
                  </button>
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
                    value={
                      canManageInternalPricing && row.pricing_mode === "markup" && row.internal_cost.trim()
                        ? computedRows[i].effectivePrice.toFixed(2)
                        : row.unit_price
                    }
                    disabled={canManageInternalPricing && row.pricing_mode === "markup" && !!row.internal_cost.trim()}
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
                {canManageInternalPricing && (
                  <div className="col-span-12 rounded-md border border-dashed border-border bg-surface-hover/40 p-3">
                    <div className="mb-2 text-[11px] font-semibold uppercase tracking-widest text-text-muted">
                      İç Maliyet / Müşteri Görmez
                    </div>
                    <div className="grid grid-cols-12 items-end gap-2">
                      <div className="col-span-3">
                        <Input
                          label="Taşeron Maliyeti"
                          type="number"
                          step="0.01"
                          value={row.internal_cost}
                          onChange={(e) => updateItem(i, { internal_cost: e.target.value })}
                          placeholder="—"
                        />
                      </div>
                      <div className="col-span-4">
                        <label className="mb-1.5 block text-xs font-semibold uppercase tracking-widest text-text-muted">
                          Fiyatlama
                        </label>
                        <div className="flex items-center gap-4 pb-2 text-sm">
                          <label className="flex items-center gap-1.5">
                            <input
                              type="radio"
                              name={`pricing-mode-${i}`}
                              checked={row.pricing_mode === "markup"}
                              onChange={() => updateItem(i, { pricing_mode: "markup" })}
                            />
                            Maliyet üzerine %
                          </label>
                          <label className="flex items-center gap-1.5">
                            <input
                              type="radio"
                              name={`pricing-mode-${i}`}
                              checked={row.pricing_mode === "manual"}
                              onChange={() => updateItem(i, { pricing_mode: "manual" })}
                            />
                            Satış fiyatını elle gir
                          </label>
                        </div>
                      </div>
                      {row.pricing_mode === "markup" && (
                        <div className="col-span-2">
                          <Input
                            label="Marj (%)"
                            type="number"
                            step="0.01"
                            value={row.markup_percent}
                            onChange={(e) => updateItem(i, { markup_percent: e.target.value })}
                          />
                        </div>
                      )}
                      {row.internal_cost.trim() && (
                        <div className="col-span-3 flex flex-col gap-0.5 text-right text-xs">
                          <span className="text-text-muted">
                            Müşteri Fiyatı:{" "}
                            <span className="font-medium text-text">
                              {formatTL(computedRows[i].effectivePrice)}
                            </span>
                          </span>
                          <span className="text-text-muted">
                            Beklenen Kâr:{" "}
                            <span
                              className={`font-medium ${
                                (computedRows[i].expectedProfit ?? 0) < 0 ? "text-danger" : "text-success"
                              }`}
                            >
                              {formatTL(computedRows[i].expectedProfit ?? 0)}
                            </span>
                          </span>
                        </div>
                      )}
                    </div>
                  </div>
                )}
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

      {/* Formun DIŞINDA (iç içe <form> olmasın): yeni müşteri sayfa
          değiştirmeden oluşturulur, teklif taslağı korunur ve oluşturulan
          müşteri doğrudan seçilir. */}
      <Modal open={newCustomerOpen} onClose={() => setNewCustomerOpen(false)} title="Yeni Müşteri">
        {newCustomerOpen && (
          <CustomerCreateForm
            initialName={customerIsLinked ? "" : customer.customer_name}
            onCreated={handleCustomerCreated}
            onCancel={() => setNewCustomerOpen(false)}
          />
        )}
      </Modal>

      <Card className="h-fit w-full lg:w-72">
        <CardHeader>Özet</CardHeader>
        <CardBody className="flex flex-col gap-3">
          <div className="flex flex-col gap-1">
            <DateInput
              label="Geçerlilik Tarihi"
              value={validUntil}
              min={todayISO()}
              onChange={(e) => setValidUntil(e.target.value)}
            />
            <p className="text-xs text-text-muted">
              Müşteri bu tarihten sonra teklifi onaylayamaz. Boş bırakılırsa süresizdir.
            </p>
          </div>
          <div className="flex flex-col gap-1.5">
            <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
              KDV (%)
            </label>
            <input
              type="number"
              step="0.01"
              min={0}
              max={100}
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

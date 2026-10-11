"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";

import { Trash2 } from "lucide-react";

import { MetrajHesaplaPanel, type MetrajOfferItemDraft } from "@/components/calc/MetrajHesaplaPanel";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney } from "@/lib/format";
import {
  catalogLinkOf,
  countZeroPriced,
  OFFER_DEFAULTS_PATH,
  offerCurrency,
  offerCurrencyNote,
  offerDefaultsPatch,
  pickCatalogProduct,
  renameCatalogItem,
  validUntilHint,
  validUntilPayload,
  zeroPriceConfirmMessage,
  type CatalogLink,
  type OfferDefaults,
} from "@/lib/offers";
import type { CalcSnapshot, Customer, Offer, OfferItemPricingMode, Product } from "@/lib/types";

import { CustomerCreateForm } from "../musteriler/yeni/NewCustomerForm";
import { OfferProductNameField } from "./OfferProductNameField";

// Kalemin katalog bağı (CatalogLink): product_id yalnızca ad, bağlandığı
// ürünün adıyla aynıyken gönderilir -- katalogdan KİMLİKLE seçilir, ad sonra
// değişirse bağ düşer (bkz. lib/offers.ts renameCatalogItem).
interface ItemRow extends CatalogLink {
  // Satırın istemci tarafı anahtarı (yalnızca React key): ortadaki bir satır
  // silinince öneri alanının durumu bir alttaki satıra kaymasın. Gönderilmez;
  // sunucu ve tarayıcı sayaçları farklı olabileceğinden DOM'a da yazılmaz
  // (hydration uyuşmazlığı olurdu).
  key: string;
  // Düzenlenen taslakta satırın karşılık geldiği mevcut kalemin id'si (yeni
  // satırlarda null). Backend, iç fiyatlama yetkisi olmayan düzenleyicinin
  // kaydında mevcut kalemlerin iç maliyetini bu id ile taşır -- id
  // gönderilmezse o maliyetleri silmemek için kaydı reddeder.
  id: string | null;
  product_name: string;
  quantity: string;
  unit_price: string;
  // Birim: katalogdan seçimde ürünün birimiyle dolar (mobil gibi), elle de
  // yazılabilir. Eskiden formda alanı yoktu, kalem birimsiz kaydediliyordu.
  unit: string;
  // Metraj Hesaplama entegrasyonu — serbest/elle eklenen satırlarda hepsi
  // boş/null kalır.
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

let rowKeySeq = 0;
const newRowKey = () => `satir-${++rowKeySeq}`;

const emptyRow = (): ItemRow => ({
  key: newRowKey(),
  id: null,
  ...catalogLinkOf(null, ""),
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
    key: newRowKey(),
    id: it.id,
    ...catalogLinkOf(it.product_id, it.product_name),
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
    key: newRowKey(),
    id: null,
    ...catalogLinkOf(draft.product_id, draft.product_name),
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
  const { confirm, dialog: confirmDialog } = useConfirmDialog();
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [customerId, setCustomerId] = useState<string | null>(offer?.customer_id ?? null);
  const [customer, setCustomer] = useState({
    customer_name: offer?.customer_name ?? "",
    customer_phone: offer?.customer_phone ?? "",
    customer_email: offer?.customer_email ?? "",
    customer_address: offer?.customer_address ?? "",
    notes: offer?.notes ?? "",
  });
  // Yeni teklifte KDV, geçerlilik ve para birimi firma varsayılanlarından
  // (GET /offers/defaults, kurulumdaki "Teklif" adımı) gelir; okunamazsa
  // form %20 ile açık kalır, kayıt engellenmez (mobil ile aynı).
  const [vatRate, setVatRate] = useState(String(offer?.vat_rate ?? 20));
  // Geçerlilik tarihi: boş = süresiz. Düzenlemede kaydederken HER ZAMAN
  // gönderilir ("" = temizle); yeni teklifte kullanıcı dokunmadıysa null
  // gider ve firma süresini sunucu uygular (bkz. validUntilPayload).
  const [validUntil, setValidUntil] = useState(offer?.valid_until ?? "");
  const [validUntilTouched, setValidUntilTouched] = useState(false);
  // Geç gelen varsayılan, kullanıcının o ana kadar elle değiştirdiği alanı
  // ezmesin -- yanıt geldiğinde okunur (state kapanışta bayat kalırdı).
  const touchedRef = useRef({ vatRate: false, validUntil: false });
  const [defaults, setDefaults] = useState<OfferDefaults | null>(null);
  // Teklifin para birimi: düzenlemede teklifinki (değişmez), yenide firma
  // varsayılanı. Tüm tutarlar bu birimde gösterilir.
  const [currency, setCurrency] = useState(() => offerCurrency(offer));
  const [items, setItems] = useState<ItemRow[]>(() => offerToRows(offer));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [metrajOpen, setMetrajOpen] = useState(false);
  const [newCustomerOpen, setNewCustomerOpen] = useState(false);
  const [suggestOpen, setSuggestOpen] = useState(false);
  // Müşteri listesi yüklenemezse bunu söyleriz -- eskiden hata
  // yutuluyordu ve kullanıcı boş öneri listesini "kayıt yok" sanıyordu.
  // Ürün kataloğu artık topluca çekilmez: kalem adında yazdıkça aranır
  // (OfferProductNameField, GET /products?q=…&limit=6).
  const [loadErrors, setLoadErrors] = useState<string[]>([]);

  useEffect(() => {
    const fail = (what: string) => (err: unknown) => {
      const detail = err instanceof ApiError ? err.message : "bağlantı hatası";
      setLoadErrors((prev) => [...prev, `${what} yüklenemedi (${detail}). Sayfayı yenileyip tekrar deneyin.`]);
    };
    if (canReadCustomers) {
      apiClient<{ customers: Customer[] }>("/api/v1/customers?filter=aktif")
        .then((res) => setCustomers(res.customers))
        .catch(fail("Müşteri listesi"));
    }
  }, [canReadCustomers]);

  // Firma varsayılanları yalnızca yeni teklifte (düzenlemede teklifin kendi
  // değerleri geçerli). Okunamazsa sessizce %20 ile devam: kayıtta
  // dokunulmamış geçerlilik null gider, firma süresini sunucu yine uygular.
  useEffect(() => {
    if (isEdit) return;
    let cancelled = false;
    apiClient<OfferDefaults>(OFFER_DEFAULTS_PATH)
      .then((d) => {
        if (cancelled) return;
        const patch = offerDefaultsPatch(d, touchedRef.current);
        setDefaults(d);
        setCurrency(patch.currency);
        if (patch.vatRate !== undefined) setVatRate(patch.vatRate);
        if (patch.validUntil !== undefined) setValidUntil(patch.validUntil);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [isEdit]);

  function handleVatRate(value: string) {
    touchedRef.current.vatRate = true;
    setVatRate(value);
  }

  function handleValidUntil(value: string) {
    touchedRef.current.validUntil = true;
    setValidUntilTouched(true);
    setValidUntil(value);
  }

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

  // Ad değişti: katalog bağı yalnızca ad bağlandığı adla aynıyken korunur
  // (eskiden ürün ADLA eşleşiyordu -- aynı adlı iki üründen hep ilki).
  function handleProductName(index: number, name: string) {
    setItems((prev) => prev.map((row, i) => (i === index ? renameCatalogItem(row, name) : row)));
  }

  // Katalogdan seçildi: kimlikle bağlanır; ad, birim ve birim fiyat dolar.
  function handleProductPick(index: number, product: Product) {
    setItems((prev) => prev.map((row, i) => (i === index ? pickCatalogProduct(row, product) : row)));
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
  const money = (value: number) => formatMoney(value, currency);
  const currencyNote = offerCurrencyNote(currency, isEdit);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    const payloadItems = items
      .filter((r) => r.product_name.trim() && parseNum(r.quantity) > 0)
      .map((r) => ({
        id: r.id,
        product_id: r.product_id,
        product_name: r.product_name.trim(),
        quantity: parseNum(r.quantity),
        unit_price: effectiveUnitPrice(r),
        unit: r.unit.trim(),
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
      }));
    // 0 fiyatlı kalem geçerlidir (ikram/hediye) ama çoğunlukla fiyatı
    // olmayan ürün ya da metraj satırıdır -- sessizce kaydedilmesin (mobil).
    const zeroPriced = countZeroPriced(payloadItems);
    if (
      zeroPriced > 0 &&
      !(await confirm({
        title: "Fiyatı 0 olan kalem var",
        message: zeroPriceConfirmMessage(zeroPriced, currency),
        confirmLabel: "Yine de Kaydet",
      }))
    ) {
      return;
    }
    setLoading(true);
    try {
      const payload = {
        customer_id: customerId,
        ...customer,
        vat_rate: vat,
        valid_until: validUntilPayload({ isEdit, validUntil, touched: validUntilTouched }),
        items: payloadItems,
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
            {items.map((row, i) => (
              <div key={row.key} className="grid grid-cols-12 items-end gap-2">
                <div className="col-span-5">
                  <OfferProductNameField
                    label={i === 0 ? "Ürün / Hizmet" : undefined}
                    value={row.product_name}
                    catalogEnabled={canReadProducts}
                    currency={currency}
                    onChange={(name) => handleProductName(i, name)}
                    onPick={(product) => handleProductPick(i, product)}
                  />
                  {row.calc_snapshot && (
                    <p className="mt-1 text-xs text-text-muted">
                      Metraj Hesapla{row.section_label ? ` · ${row.section_label}` : ""}
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
                <div className="col-span-1">
                  <Input
                    label={i === 0 ? "Birim" : undefined}
                    value={row.unit}
                    onChange={(e) => updateItem(i, { unit: e.target.value })}
                    placeholder="adet"
                    aria-label="Birim"
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
                <div className="col-span-1 text-right text-sm font-medium">{money(computedRows[i].lineTotal)}</div>
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
                              {money(computedRows[i].effectivePrice)}
                            </span>
                          </span>
                          <span className="text-text-muted">
                            Beklenen Kâr:{" "}
                            <span
                              className={`font-medium ${
                                (computedRows[i].expectedProfit ?? 0) < 0 ? "text-danger" : "text-success"
                              }`}
                            >
                              {money(computedRows[i].expectedProfit ?? 0)}
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
            openExistingInNewTab
          />
        )}
      </Modal>
      {/* 0 TL kalem onayı -- formun DIŞINDA: düğmeleri formu göndermesin. */}
      {confirmDialog}

      <Card className="h-fit w-full lg:w-72">
        <CardHeader>Özet</CardHeader>
        <CardBody className="flex flex-col gap-3">
          <div className="flex flex-col gap-1">
            <DateInput
              label="Geçerlilik Tarihi"
              value={validUntil}
              min={todayISO()}
              onChange={(e) => handleValidUntil(e.target.value)}
            />
            <p className="text-xs text-text-muted">
              {validUntilHint({ isEdit, touched: validUntilTouched, defaults })}
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
              onChange={(e) => handleVatRate(e.target.value)}
              className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
            />
          </div>
          {currencyNote && <p className="text-xs text-text-muted">{currencyNote}</p>}
          <div className="flex justify-between text-sm text-text-muted">
            <span>Ara Toplam</span>
            <span className="font-medium text-text">{money(subtotal)}</span>
          </div>
          <div className="flex justify-between text-sm text-text-muted">
            <span>KDV Tutarı</span>
            <span className="font-medium text-text">{money(vatAmount)}</span>
          </div>
          <div className="flex justify-between border-t border-border pt-3 text-base font-bold">
            <span>Genel Toplam</span>
            <span>{money(grandTotal)}</span>
          </div>
        </CardBody>
      </Card>
    </div>
  );
}

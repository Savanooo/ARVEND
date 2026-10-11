"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Textarea } from "@/components/ui/Textarea";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import {
  emptyExpenseForm,
  expenseFormFrom,
  expenseRequestBody,
  expenseVatRateLabel,
  expenseVatRateOptions,
  expenseVatSplit,
  type ExpenseFormValues,
} from "@/lib/expenses";
import { formatMoney, istanbulDate } from "@/lib/format";
import {
  EXPENSE_CATEGORY_LABELS,
  type BudgetLine,
  type ChangeOrder,
  type Expense,
  type OrganizationCostCode,
} from "@/lib/types";

// "Masraf Ekle" / "Masrafı Düzenle" formu -- Finans > Masraflar, proje
// sayfasındaki ayrı giriş (finansı göremeyen kişi) ve Masraflarım AYNI formu
// kullanır (mobil expense_form_sheet.dart ile aynı kurallar):
//
// - KDV (backend 0065): Belirtilmedi / KDV yok (%0) / %1 / %10 / %20 ve canlı
//   "KDV hariç · KDV" önizlemesi; vat_rate YALNIZCA oran seçilince gönderilir.
// - initial verilirse PUT .../expenses/{id}: sunucu satırı BÜTÜNÜYLE yeniden
//   yazar, formun okuduğu her alan (bağlar, not, tarih, KDV) geri gider.
//   Düzenlenen masraf yeniden onay bekler; onaylı masrafta kayıttan ÖNCE sorulur.
// - canLink (projects.finance.manage) yoksa Ek İş / Bütçe Kalemi / Maliyet Kodu
//   HİÇ gösterilmez ve boş gider (sunucu dolu bağı 403 ile reddeder; boş bağ
//   düzenlemede "kayıttakini koru" demektir). Seçici listeleri verilmezse
//   (Masraflarım) alanlar görünmez ama düzenlemede okunan bağ aynen geri gider.
//
// Para birimi sorulmaz: yeni masrafta projeninki, düzenlemede masrafınki.
// Hata mesajı (403/409 dahil) sunucudan geldiği gibi gösterilir.
export function ExpenseForm({
  projectId,
  currency,
  initial = null,
  canLink,
  changeOrders = [],
  budgetLines = [],
  costCodes = [],
  idPrefix,
  onDone,
  onCancel,
}: {
  projectId: string;
  currency: string;
  initial?: Expense | null;
  canLink: boolean;
  changeOrders?: ChangeOrder[];
  budgetLines?: BudgetLine[];
  costCodes?: OrganizationCostCode[];
  // Aynı sayfada birden çok form olabilir (ekleme + düzenleme penceresi):
  // input id'leri çakışmasın.
  idPrefix: string;
  onDone: (expense: Expense) => void;
  onCancel: () => void;
}) {
  const router = useRouter();
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const [form, setForm] = useState<ExpenseFormValues>(() =>
    initial ? expenseFormFrom(initial) : emptyExpenseForm(istanbulDate(new Date()))
  );
  // Form ÖRNEĞİ başına sabit anahtar: çift tıklama/ağ tekrarı mükerrer
  // masraf açmaz; yalnızca başarılı bir kayıttan sonra yenilenir.
  // Düzenlemede kullanılmaz.
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const editing = initial !== null;
  const formCurrency = initial?.currency || currency;
  const id = (name: string) => `${idPrefix}_${name}`;

  // İptal edilmiş/yerine yenisi gelmiş ek işe bağlamak anlamsız -- ama
  // düzenlenen masrafın mevcut bağı listede kalır (aynen geri gitsin).
  const linkableChangeOrders = canLink
    ? changeOrders.filter(
        (co) => (co.status !== "cancelled" && co.status !== "superseded") || co.id === form.change_order_id
      )
    : [];
  const linkableBudgetLines = canLink ? budgetLines : [];
  const linkableCostCodes = canLink ? costCodes.filter((c) => c.is_active || c.id === form.cost_code_id) : [];

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (
      initial?.approval_status === "approved" &&
      !(await confirm({
        title: "Yeniden onaya gidecek",
        message:
          "Bu masraf onaylanmış. Düzenlenince yeniden onay bekler; onaylanana kadar gerçekleşen maliyete ve kâra girmez.",
        confirmLabel: "Kaydet",
      }))
    ) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const body = expenseRequestBody(form, {
        currency: formCurrency,
        canLink,
        idempotencyKey: editing ? undefined : idempotencyKey,
      });
      const saved = initial
        ? await apiClient<Expense>(`/api/v1/projects/${projectId}/expenses/${initial.id}`, {
            method: "PUT",
            body: JSON.stringify(body),
          })
        : await apiClient<Expense>(`/api/v1/projects/${projectId}/expenses`, {
            method: "POST",
            body: JSON.stringify(body),
          });
      if (!editing) {
        setIdempotencyKey(crypto.randomUUID());
        setForm(emptyExpenseForm(istanbulDate(new Date())));
      }
      router.refresh();
      // Masraf onay bekleyerek doğar ve düzenlenince yeniden onaya düşer:
      // toplamda hemen görünmemesinin nedeni burada söylenir (mobil ile aynı).
      toast.success(editing ? "Masraf güncellendi; yeniden onaya gönderildi." : "Masraf onaya gönderildi.");
      onDone(saved);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      // 404/409: masraf bu arada onaylanmış/iptal edilmiş ya da proje
      // kapanmış olabilir -- arkadaki liste tazelensin (form açık kalır).
      if (err instanceof ApiError && (err.status === 404 || err.status === 409)) router.refresh();
    } finally {
      setBusy(false);
    }
  }

  const categoryKnown = form.category in EXPENSE_CATEGORY_LABELS;

  // Onay penceresi formun DIŞINDA: ConfirmDialog düğmeleri type'sız
  // (varsayılan submit) ve <dialog> DOM'da yerinde durur -- form içinde
  // "Kaydet"/"Vazgeç" formu yeniden gönderip pencereyi tekrar açardı.
  return (
    <>
      {dialog}
      <form onSubmit={submit} className="flex flex-col gap-3">
        {initial && (
          <p className="text-xs text-text-muted">
            {initial.approval_status === "rejected" && initial.decision_note
              ? `Red nedeni: ${initial.decision_note}. Düzeltip kaydedince yeniden onaya gider.`
              : "Kaydedince masraf yeniden onaya gider."}
          </p>
        )}
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Select
            label="Kategori"
            id={id("category")}
            name="expense_category"
            value={form.category}
            onChange={(e) => setForm({ ...form, category: e.target.value })}
          >
            {Object.entries(EXPENSE_CATEGORY_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
            {/* Bilinmeyen (yeni sunucu) kategori düzenlemede aynen kalır. */}
            {!categoryKnown && <option value={form.category}>{form.category}</option>}
          </Select>
          <Input
            label={`Tutar (${formCurrency})`}
            id={id("amount")}
            name="expense_amount"
            type="number"
            step="0.01"
            min="0.01"
            required
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <DateInput
            label="Tarih"
            id={id("date")}
            name="expense_date"
            required
            value={form.expense_date}
            onChange={(e) => setForm({ ...form, expense_date: e.target.value })}
          />
          {/* Sahada "Tedarikçi" usta/işçi ödemesinde anlamsız kaçıyordu (mobil
              ile aynı ad); backend alanı aynı (supplier_name, serbest metin). */}
          <Input
            label="Kime ödendi (opsiyonel)"
            id={id("supplier")}
            name="expense_supplier"
            placeholder="Tedarikçi, usta ya da kişi adı"
            value={form.supplier_name}
            onChange={(e) => setForm({ ...form, supplier_name: e.target.value })}
          />
          <div className="col-span-2 md:col-span-4">
            <VatRateField
              idPrefix={idPrefix}
              rate={form.vat_rate}
              amount={form.amount}
              currency={formCurrency}
              onChange={(vat_rate) => setForm({ ...form, vat_rate })}
            />
          </div>
          <Input
            label="Fatura No (opsiyonel)"
            id={id("invoice_no")}
            name="expense_invoice_no"
            value={form.invoice_no}
            onChange={(e) => setForm({ ...form, invoice_no: e.target.value })}
          />
          {linkableChangeOrders.length > 0 && (
            <Select
              label="Ek İş (opsiyonel)"
              id={id("change_order")}
              name="expense_change_order"
              value={form.change_order_id}
              onChange={(e) => setForm({ ...form, change_order_id: e.target.value })}
            >
              <option value="">Bağlı değil</option>
              {linkableChangeOrders.map((co) => (
                <option key={co.id} value={co.id}>
                  {co.change_order_no} · {co.title}
                </option>
              ))}
            </Select>
          )}
          {linkableBudgetLines.length > 0 && (
            <Select
              label="Bütçe Kalemi (opsiyonel)"
              id={id("budget_line")}
              name="expense_budget_line"
              value={form.budget_line_id}
              onChange={(e) => {
                const line = linkableBudgetLines.find((l) => l.id === e.target.value);
                setForm({
                  ...form,
                  budget_line_id: e.target.value,
                  // Maliyet kodu seçilen bütçe kaleminden OTOMATİK gelir --
                  // backend aynı kuralı otoriter olarak uygular, bu yalnızca UX.
                  cost_code_id: line ? line.cost_code_id : form.cost_code_id,
                });
              }}
            >
              <option value="">Bağlı değil (bütçe dışı)</option>
              {linkableBudgetLines.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.cost_code_code ? `${l.description} (${l.cost_code_code})` : l.description}
                </option>
              ))}
            </Select>
          )}
          {linkableCostCodes.length > 0 && (
            <Select
              label="Maliyet Kodu (opsiyonel)"
              id={id("cost_code")}
              name="expense_cost_code"
              value={form.cost_code_id}
              disabled={!!form.budget_line_id}
              onChange={(e) => setForm({ ...form, cost_code_id: e.target.value })}
            >
              <option value="">Yok</option>
              {linkableCostCodes.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.code} — {c.name}
                </option>
              ))}
            </Select>
          )}
          <div className="col-span-2">
            <Input
              label="Açıklama"
              id={id("description")}
              name="expense_description"
              required
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
            />
          </div>
        </div>
        <Textarea
          label="Not"
          id={id("notes")}
          name="expense_notes"
          className="min-h-16"
          value={form.notes}
          onChange={(e) => setForm({ ...form, notes: e.target.value })}
        />
        {error && <p className="text-xs text-danger">{error}</p>}
        <div className="flex gap-2">
          <Button type="submit" loading={busy}>
            Kaydet
          </Button>
          <Button type="button" variant="ghost" onClick={onCancel} disabled={busy}>
            Vazgeç
          </Button>
        </div>
      </form>
    </>
  );
}

// KDV seçimi: Belirtilmedi (varsayılan) / KDV yok (%0) / %1 / %10 / %20;
// standart dışı kayıtlı oran (API'den girilmiş ör. %18) seçili görünür.
// Oran seçilince tutarın (KDV dahil ödenen) altında canlı önizleme.
function VatRateField({
  idPrefix,
  rate,
  amount,
  currency,
  onChange,
}: {
  idPrefix: string;
  rate: number | null;
  amount: string;
  currency: string;
  onChange: (rate: number | null) => void;
}) {
  const labelId = `${idPrefix}_vat_label`;
  const split = rate == null ? null : expenseVatSplit(Number(amount), rate);
  const chip = (selected: boolean) =>
    `rounded-md border px-3 py-1.5 text-xs font-medium transition-colors ${
      selected ? "border-gold bg-gold-soft text-text" : "border-border text-text-muted hover:bg-surface-hover hover:text-text"
    }`;
  return (
    <div className="flex flex-col gap-1.5">
      <span id={labelId} className="text-xs font-semibold uppercase tracking-widest text-text-muted">
        KDV
      </span>
      <div role="group" aria-labelledby={labelId} className="flex flex-wrap gap-2">
        <button type="button" aria-pressed={rate == null} onClick={() => onChange(null)} className={chip(rate == null)}>
          Belirtilmedi
        </button>
        {expenseVatRateOptions(rate).map((r) => (
          <button key={r} type="button" aria-pressed={rate === r} onClick={() => onChange(r)} className={chip(rate === r)}>
            {expenseVatRateLabel(r)}
          </button>
        ))}
      </div>
      {rate != null && (
        <p className="text-xs text-text-muted" aria-live="polite">
          {split
            ? `KDV hariç: ${formatMoney(split.net, currency)} · KDV: ${formatMoney(split.vat, currency)}`
            : "Tutar KDV dahil ödenen tutardır."}
        </p>
      )}
    </div>
  );
}

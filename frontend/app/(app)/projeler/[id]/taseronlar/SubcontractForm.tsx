"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Textarea } from "@/components/ui/Textarea";
import { buttonClass } from "@/components/ui/styles";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney, parseAmountTR } from "@/lib/format";
import {
  buildSovItems,
  emptySovDraft,
  numberText,
  round2,
  sovDraftAmount,
  sovDraftFromItem,
  subcontractHref,
  subcontractsTabHref,
  type SovDraft,
  type Subcontract,
  type SubcontractItem,
} from "@/lib/subcontracts";
import type { BudgetLine, OrganizationCostCode, Project, Supplier, WBSNode } from "@/lib/types";

import { BudgetLineSelect, CostCodeSelect, inputClass, WbsSelect } from "./shared";

// Taşeron Sözleşmesi Ekle/Düzenle (mobil SubcontractFormScreen karşılığı).
// Düzenleme YALNIZCA taslakta (backend ErrSubcontractNotEditable) ve PUT
// kalemleri BÜTÜNÜYLE yeniden yazar -- bu yüzden mevcut kalemler (WBS,
// bütçe kalemi, miktar/birim fiyat dahil) taslağa yüklenir ve dokunulmasa
// bile olduğu gibi geri gönderilir. Sözleşme tutarı kalemlerden TÜRETİLİR;
// ayrı bir "tutar" alanı yoktur.

function supplierLabel(s: Pick<Supplier, "code" | "legal_name" | "trade_name">) {
  const name = s.trade_name || s.legal_name;
  return s.code ? `${s.code} — ${name}` : name;
}

export function SubcontractForm({
  project,
  subcontract,
  items,
  suppliers,
  costCodes,
  budgetLines,
  wbsNodes,
}: {
  project: Project;
  // Doluysa düzenleme (PUT), boşsa yeni sözleşme (POST).
  subcontract?: Subcontract;
  items?: SubcontractItem[];
  // null: listeyi okuma izni yok (organization.suppliers.read /
  // organization.cost_codes.read / projects.budget.read).
  suppliers: Supplier[] | null;
  costCodes: OrganizationCostCode[] | null;
  budgetLines: BudgetLine[] | null;
  wbsNodes: WBSNode[] | null;
}) {
  const router = useRouter();
  const isEdit = Boolean(subcontract);
  const [form, setForm] = useState({
    supplier_id: subcontract?.supplier_id ?? "",
    title: subcontract?.title ?? "",
    scope_summary: subcontract?.scope_summary ?? "",
    effective_date: subcontract?.effective_date ?? "",
    start_date: subcontract?.start_date ?? "",
    planned_completion_date: subcontract?.planned_completion_date ?? "",
    retention_percent: numberText(subcontract?.retention_percent),
    advance_amount: numberText(subcontract?.advance_amount),
    payment_terms: subcontract?.payment_terms ?? "",
    notes: subcontract?.notes ?? "",
  });
  const [drafts, setDrafts] = useState<SovDraft[]>(() =>
    items && items.length > 0 ? items.map(sovDraftFromItem) : [emptySovDraft()]
  );
  const [rowErrors, setRowErrors] = useState<Record<number, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const supplierOptions = (suppliers ?? []).filter((s) => s.is_active || s.id === form.supplier_id);
  // Tedarikçi listesi okunamıyorsa düzenlemede mevcut taşeron tek seçenek olarak kalır.
  const currentSupplierMissing = form.supplier_id !== "" && !supplierOptions.some((s) => s.id === form.supplier_id);

  function setDraft(i: number, patch: Partial<SovDraft>) {
    setDrafts(drafts.map((d, j) => (j === i ? { ...d, ...patch } : d)));
  }

  const total = round2(
    drafts.reduce((sum, d) => {
      const a = sovDraftAmount(d);
      return Number.isFinite(a) && a > 0 ? sum + a : sum;
    }, 0)
  );

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!form.supplier_id) return setError("Tedarikçi (taşeron) seçin.");
    if (!form.title.trim()) return setError("Başlık gerekli.");
    let retention: number | null = null;
    if (form.retention_percent.trim() !== "") {
      retention = parseAmountTR(form.retention_percent);
      if (!Number.isFinite(retention) || retention < 0 || retention > 100) {
        return setError("Hakediş kesintisi oranı 0 ile 100 arasında olmalı.");
      }
    }
    let advance: number | null = null;
    if (form.advance_amount.trim() !== "") {
      advance = parseAmountTR(form.advance_amount);
      if (!Number.isFinite(advance) || advance < 0) return setError("Avans tutarı geçersiz.");
    }
    const built = buildSovItems(drafts);
    setRowErrors(built.errors);
    if (Object.keys(built.errors).length > 0) return setError("Kalemlerdeki hataları düzeltin.");
    if (built.items.length === 0) {
      return setError("En az bir geçerli SOV kalemi girin (maliyet kodu, açıklama, tutar > 0).");
    }

    setSaving(true);
    try {
      const body = JSON.stringify({
        supplier_id: form.supplier_id,
        title: form.title.trim(),
        scope_summary: form.scope_summary.trim(),
        effective_date: form.effective_date || null,
        start_date: form.start_date || null,
        planned_completion_date: form.planned_completion_date || null,
        retention_percent: retention,
        advance_amount: advance,
        payment_terms: form.payment_terms.trim(),
        notes: form.notes.trim(),
        items: built.items,
      });
      const saved = subcontract
        ? await apiClient<Subcontract>(`/api/v1/projects/${project.id}/subcontracts/${subcontract.id}`, {
            method: "PUT",
            body,
          })
        : await apiClient<Subcontract>(`/api/v1/projects/${project.id}/subcontracts`, { method: "POST", body });
      router.push(subcontractHref(project.id, saved.id));
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setSaving(false);
    }
  }

  const cancelHref = subcontract ? subcontractHref(project.id, subcontract.id) : subcontractsTabHref(project.id);

  return (
    <form onSubmit={submit} className="flex flex-col gap-6 p-8">
      <Card>
        <CardHeader>Tedarikçi ve Kapsam</CardHeader>
        <CardBody className="flex flex-col gap-4">
          {suppliers === null && (
            <p className="text-xs text-danger">
              Tedarikçi listesini görme yetkiniz yok; taşeron seçmek için &quot;Tedarikçiler&quot; görüntüleme yetkisi gerekir.
            </p>
          )}
          <Select
            label="Tedarikçi (Taşeron)"
            name="supplier_id"
            value={form.supplier_id}
            onChange={(e) => setForm({ ...form, supplier_id: e.target.value })}
          >
            <option value="">Tedarikçi seçin…</option>
            {currentSupplierMissing && subcontract && (
              <option value={subcontract.supplier_id}>
                {subcontract.supplier_name || subcontract.supplier_code || "Mevcut tedarikçi"}
              </option>
            )}
            {supplierOptions.map((s) => (
              <option key={s.id} value={s.id}>
                {supplierLabel(s)}
                {s.is_active ? "" : " (pasif)"}
              </option>
            ))}
          </Select>
          <Input
            label="Başlık"
            name="title"
            value={form.title}
            onChange={(e) => setForm({ ...form, title: e.target.value })}
            placeholder="ör. Elektrik tesisatı işleri"
          />
          <Textarea
            label="Kapsam Özeti (opsiyonel)"
            name="scope_summary"
            value={form.scope_summary}
            onChange={(e) => setForm({ ...form, scope_summary: e.target.value })}
          />
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Ticari Şartlar</CardHeader>
        <CardBody className="flex flex-col gap-4">
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <DateInput
              label="Yürürlük Tarihi (opsiyonel)"
              name="effective_date"
              value={form.effective_date}
              onChange={(e) => setForm({ ...form, effective_date: e.target.value })}
            />
            <DateInput
              label="Başlangıç Tarihi (opsiyonel)"
              name="start_date"
              value={form.start_date}
              onChange={(e) => setForm({ ...form, start_date: e.target.value })}
            />
            <DateInput
              label="Planlanan Bitiş (opsiyonel)"
              name="planned_completion_date"
              value={form.planned_completion_date}
              onChange={(e) => setForm({ ...form, planned_completion_date: e.target.value })}
            />
          </div>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <Input
              label="Hakediş Kesintisi % (opsiyonel)"
              name="retention_percent"
              inputMode="decimal"
              placeholder="ör. 5"
              value={form.retention_percent}
              onChange={(e) => setForm({ ...form, retention_percent: e.target.value })}
            />
            <Input
              label={`Avans Tutarı (${project.currency}, opsiyonel)`}
              name="advance_amount"
              inputMode="decimal"
              value={form.advance_amount}
              onChange={(e) => setForm({ ...form, advance_amount: e.target.value })}
            />
            <Input
              label="Ödeme Koşulları (opsiyonel)"
              name="payment_terms"
              value={form.payment_terms}
              onChange={(e) => setForm({ ...form, payment_terms: e.target.value })}
            />
          </div>
          <p className="text-xs text-text-muted">
            Aktifleştirmeden sonra ticari şartlar ve kalemler kilitlenir; sonraki değişiklikler değişiklik emriyle yapılır.
          </p>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Kalemler (SOV)</CardHeader>
        <CardBody className="flex flex-col gap-3">
          {costCodes === null && (
            <p className="text-xs text-danger">
              Maliyet kodu listesini görme yetkiniz yok; her kalem için maliyet kodu zorunludur.
            </p>
          )}
          <p className="text-xs text-text-muted">
            Miktar ve birim fiyat birlikte girilirse tutar ikisinin çarpımıdır; aksi halde tutarı doğrudan girin.
          </p>
          {drafts.map((d, i) => {
            const computed = d.quantity.trim() !== "" && d.unit_price.trim() !== "";
            const amount = sovDraftAmount(d);
            return (
              <div key={i} className="flex flex-col gap-2 rounded-md border border-border p-3">
                <div className="grid grid-cols-12 gap-2">
                  <input
                    className={`${inputClass} col-span-12 md:col-span-6`}
                    placeholder="Açıklama"
                    value={d.description}
                    onChange={(e) => setDraft(i, { description: e.target.value })}
                  />
                  <CostCodeSelect
                    className="col-span-10 md:col-span-5"
                    value={d.cost_code_id}
                    onChange={(v) => setDraft(i, { cost_code_id: v })}
                    costCodes={costCodes ?? []}
                  />
                  <button
                    type="button"
                    className="col-span-2 text-xs text-danger disabled:opacity-40 md:col-span-1"
                    disabled={drafts.length <= 1}
                    onClick={() => setDrafts(drafts.filter((_, j) => j !== i))}
                  >
                    Sil
                  </button>
                  <input
                    className={`${inputClass} col-span-6 md:col-span-2`}
                    inputMode="decimal"
                    placeholder="Miktar"
                    value={d.quantity}
                    onChange={(e) => setDraft(i, { quantity: e.target.value })}
                  />
                  <input
                    className={`${inputClass} col-span-6 md:col-span-2`}
                    placeholder="Birim"
                    value={d.unit}
                    onChange={(e) => setDraft(i, { unit: e.target.value })}
                  />
                  <input
                    className={`${inputClass} col-span-6 md:col-span-3`}
                    inputMode="decimal"
                    placeholder="Birim Fiyat"
                    value={d.unit_price}
                    onChange={(e) => setDraft(i, { unit_price: e.target.value })}
                  />
                  {computed ? (
                    <div className={`${inputClass} col-span-6 bg-surface-hover text-right md:col-span-5`}>
                      {Number.isFinite(amount) ? formatMoney(amount, project.currency) : "—"}
                    </div>
                  ) : (
                    <input
                      className={`${inputClass} col-span-6 text-right md:col-span-5`}
                      inputMode="decimal"
                      placeholder={`Tutar (${project.currency})`}
                      value={d.amount}
                      onChange={(e) => setDraft(i, { amount: e.target.value })}
                    />
                  )}
                  <BudgetLineSelect
                    className="col-span-12 md:col-span-6"
                    value={d.budget_line_id}
                    onChange={(v) => setDraft(i, { budget_line_id: v })}
                    budgetLines={budgetLines}
                    costCodeId={d.cost_code_id}
                  />
                  <WbsSelect
                    className="col-span-12 md:col-span-6"
                    value={d.wbs_node_id}
                    onChange={(v) => setDraft(i, { wbs_node_id: v })}
                    wbsNodes={wbsNodes}
                  />
                </div>
                {rowErrors[i] && <p className="text-xs text-danger">{rowErrors[i]}</p>}
              </div>
            );
          })}
          <div className="flex flex-wrap items-center justify-between gap-2">
            <Button type="button" variant="ghost" onClick={() => setDrafts([...drafts, emptySovDraft()])}>
              + Kalem Ekle
            </Button>
            <span className="text-sm">
              Sözleşme tutarı (kalemler toplamı):{" "}
              <span className="font-semibold">{formatMoney(total, project.currency)}</span>
            </span>
          </div>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>Notlar</CardHeader>
        <CardBody>
          <Textarea
            name="notes"
            value={form.notes}
            onChange={(e) => setForm({ ...form, notes: e.target.value })}
            placeholder="Notlar (opsiyonel)"
          />
        </CardBody>
      </Card>

      {error && <p className="text-sm text-danger">{error}</p>}
      <div className="flex gap-2">
        <Button type="submit" loading={saving}>
          {isEdit ? "Kaydet" : "Sözleşmeyi Oluştur"}
        </Button>
        <Link href={cancelHref} className={buttonClass("ghost")}>
          Vazgeç
        </Link>
      </div>
    </form>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useRef, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney } from "@/lib/format";
import {
  EXPENSE_CATEGORY_LABELS,
  INVOICE_STATUS_LABELS,
  PLAN_ITEM_STATUS_LABELS,
  SUBCONTRACTOR_STATUS_LABELS,
  type Collection,
  type Expense,
  type ExpenseCategory,
  type InvoiceStatus,
  type PaymentPlanItem,
  type PlanItemStatus,
  type Project,
  type ProjectInvoice,
  type Subcontractor,
  type SubcontractorPayment,
} from "@/lib/types";

const inputClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text placeholder:text-text-muted/60 outline-none focus:border-gold";

const PLAN_TONE: Record<PlanItemStatus, "muted" | "gold" | "success" | "danger"> = {
  pending: "muted",
  partial: "gold",
  paid: "success",
  overdue: "danger",
  cancelled: "muted",
};

const INVOICE_TONE: Record<InvoiceStatus, "muted" | "gold" | "success" | "danger"> = {
  draft: "muted",
  issued: "gold",
  sent: "gold",
  paid: "success",
  cancelled: "danger",
};

// Anahtar form ÖRNEĞİ başına bir kez üretilir ve tekrar denemelerde AYNI
// kalır; yalnızca kayıt başarıyla oluştuktan sonra yenilenir. Anahtarı her
// gönderimde yeniden üretmek, çift tıklamada iki FARKLI anahtar göndermek
// demek olurdu -- yani idempotency tam da korumak istediği durumda
// çalışmazdı (bkz. project_collections.idempotency_key).
function newIdempotencyKey() {
  return crypto.randomUUID();
}

function useFinanceAction(locked: boolean) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<unknown>) {
    if (locked) return;
    setBusy(true);
    setError(null);
    try {
      await fn();
      router.refresh();
      return true;
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      return false;
    } finally {
      setBusy(false);
    }
  }
  return { busy, error, run };
}

function LockedNote({ project }: { project: Project }) {
  if (project.status === "cancelled") {
    return (
      <p className="text-xs text-text-muted">
        Bu proje iptal edilmiş; yeni finans hareketi eklenemez. Geçmiş kayıtlar görüntülenebilir.
      </p>
    );
  }
  return (
    <p className="text-xs text-text-muted">
      Proje tamamlandı; finans hareketleri kilitli. Yeni hareket girmek için projeyi
      &quot;Devam Ediyor&quot; durumuna alın.
    </p>
  );
}

// ---------- Ödeme Planı ----------

export function PaymentPlanSection({
  project,
  items,
  plannedTotal,
  locked,
}: {
  project: Project;
  items: PaymentPlanItem[];
  plannedTotal: number;
  locked: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ name: "", percentage: "", planned_amount: "", due_date: "" });

  async function submit(e: FormEvent) {
    e.preventDefault();
    const body: Record<string, unknown> = {
      name: form.name,
      due_date: form.due_date || null,
      sort_order: items.length,
    };
    if (form.percentage) body.percentage = Number(form.percentage);
    else body.planned_amount = Number(form.planned_amount);
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/payment-plan`, {
        method: "POST",
        body: JSON.stringify(body),
      })
    );
    if (ok) {
      setForm({ name: "", percentage: "", planned_amount: "", due_date: "" });
      setOpen(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {items.length === 0 ? (
        <p className="text-text-muted">Henüz ödeme planı kalemi yok.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase tracking-widest text-text-muted">
                <th className="pb-2">Kalem</th>
                <th className="pb-2">Vade</th>
                <th className="pb-2 text-right">Planlanan</th>
                <th className="pb-2 text-right">Tahsil</th>
                <th className="pb-2 text-right">Kalan</th>
                <th className="pb-2">Durum</th>
                <th className="pb-2"></th>
              </tr>
            </thead>
            <tbody>
              {items.map((it) => (
                <tr key={it.id} className="border-t border-border">
                  <td className="py-2">
                    {it.name}
                    {it.percentage !== null && (
                      <span className="ml-1 text-xs text-text-muted">%{it.percentage}</span>
                    )}
                  </td>
                  <td className="py-2 text-text-muted">
                    {it.due_date ? new Date(it.due_date).toLocaleDateString("tr-TR") : "—"}
                  </td>
                  <td className="py-2 text-right">{formatMoney(it.planned_amount, project.currency)}</td>
                  <td className="py-2 text-right">{formatMoney(it.collected_amount, project.currency)}</td>
                  <td className="py-2 text-right">{formatMoney(it.remaining_amount, project.currency)}</td>
                  <td className="py-2">
                    <Badge tone={PLAN_TONE[it.status]}>{PLAN_ITEM_STATUS_LABELS[it.status]}</Badge>
                  </td>
                  <td className="py-2 text-right">
                    {!locked && it.status !== "cancelled" && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() =>
                          run(() =>
                            apiClient(`/api/v1/projects/${project.id}/payment-plan/${it.id}`, {
                              method: "DELETE",
                            })
                          )
                        }
                        className="text-xs text-danger hover:underline"
                      >
                        İptal
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="flex items-center justify-between border-t border-border pt-2 text-sm">
        <span className="text-text-muted">Toplam plan tutarı</span>
        <span className="font-medium">{formatMoney(plannedTotal, project.currency)}</span>
      </div>
      {Math.abs(plannedTotal - project.contract_amount) >= 0.005 && items.length > 0 && (
        <p className="text-xs text-text-muted">
          Plan toplamı sözleşme bedelinden ({formatMoney(project.contract_amount, project.currency)}){" "}
          farklı — özel plan oluşturulmuş olabilir.
        </p>
      )}

      {locked ? (
        <LockedNote project={project} />
      ) : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <input
            className={inputClass}
            placeholder="Kalem adı (ör. Peşinat)"
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <input
            className={`${inputClass} w-28`}
            placeholder="Yüzde"
            type="number"
            step="0.01"
            value={form.percentage}
            onChange={(e) => setForm({ ...form, percentage: e.target.value, planned_amount: "" })}
          />
          <input
            className={`${inputClass} w-36`}
            placeholder="veya tutar"
            type="number"
            step="0.01"
            value={form.planned_amount}
            onChange={(e) => setForm({ ...form, planned_amount: e.target.value, percentage: "" })}
          />
          <input
            className={inputClass}
            type="date"
            value={form.due_date}
            onChange={(e) => setForm({ ...form, due_date: e.target.value })}
          />
          <Button type="submit" disabled={busy}>
            {busy ? "Ekleniyor…" : "Ekle"}
          </Button>
          <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
            Vazgeç
          </Button>
        </form>
      ) : (
        <div>
          <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
            + Plan Kalemi Ekle
          </Button>
        </div>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Tahsilatlar ----------

export function CollectionsSection({
  project,
  collections,
  planItems,
  locked,
}: {
  project: Project;
  collections: Collection[];
  planItems: PaymentPlanItem[];
  locked: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const [open, setOpen] = useState(false);
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);
  const [form, setForm] = useState({
    amount: "",
    received_date: new Date().toISOString().slice(0, 10),
    payment_method: "",
    description: "",
    reference_no: "",
    payment_plan_item_id: "",
  });

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/collections`, {
        method: "POST",
        body: JSON.stringify({
          amount: Number(form.amount),
          currency: project.currency,
          received_date: form.received_date,
          payment_method: form.payment_method,
          description: form.description,
          reference_no: form.reference_no,
          payment_plan_item_id: form.payment_plan_item_id || null,
          idempotency_key: idempotencyKey,
        }),
      })
    );
    if (ok) {
      // Yalnızca kayıt kesinleştikten sonra yeni anahtar: başarısız bir
      // denemenin tekrarı aynı anahtarla gider, mükerrer kayıt olmaz.
      setIdempotencyKey(newIdempotencyKey());
      setForm({ ...form, amount: "", description: "", reference_no: "" });
      setOpen(false);
    }
  }

  const activePlanItems = planItems.filter((i) => i.status !== "cancelled");

  return (
    <div className="flex flex-col gap-3">
      {collections.length === 0 ? (
        <p className="text-text-muted">Henüz tahsilat kaydı yok.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase tracking-widest text-text-muted">
                <th className="pb-2">Tarih</th>
                <th className="pb-2">Açıklama</th>
                <th className="pb-2">Yöntem</th>
                <th className="pb-2 text-right">Tutar</th>
                <th className="pb-2"></th>
              </tr>
            </thead>
            <tbody>
              {collections.map((c) => (
                <tr key={c.id} className={`border-t border-border ${c.voided_at ? "opacity-50" : ""}`}>
                  <td className="py-2 text-text-muted">
                    {new Date(c.received_date).toLocaleDateString("tr-TR")}
                  </td>
                  <td className="py-2">
                    {c.description || "—"}
                    {c.voided_at && (
                      <span className="ml-2 text-xs text-danger">
                        İPTAL{c.void_reason && ` · ${c.void_reason}`}
                      </span>
                    )}
                  </td>
                  <td className="py-2 text-text-muted">{c.payment_method || "—"}</td>
                  <td className={`py-2 text-right ${c.voided_at ? "line-through" : "font-medium"}`}>
                    {formatMoney(c.amount, c.currency)}
                  </td>
                  <td className="py-2 text-right">
                    {!c.voided_at && !locked && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => {
                          const reason = prompt("İptal nedeni:") ?? "";
                          run(() =>
                            apiClient(`/api/v1/projects/${project.id}/collections/${c.id}/void`, {
                              method: "POST",
                              body: JSON.stringify({ reason }),
                            })
                          );
                        }}
                        className="text-xs text-danger hover:underline"
                      >
                        İptal Et
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {locked ? (
        <LockedNote project={project} />
      ) : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <input
            className={`${inputClass} w-36`}
            placeholder="Tutar"
            type="number"
            step="0.01"
            required
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <input
            className={inputClass}
            type="date"
            required
            value={form.received_date}
            onChange={(e) => setForm({ ...form, received_date: e.target.value })}
          />
          <select
            className={inputClass}
            value={form.payment_plan_item_id}
            onChange={(e) => setForm({ ...form, payment_plan_item_id: e.target.value })}
            aria-label="Ödeme planı kalemi"
          >
            <option value="">Plan kalemi (opsiyonel)</option>
            {activePlanItems.map((i) => (
              <option key={i.id} value={i.id}>
                {i.name}
              </option>
            ))}
          </select>
          <input
            className={inputClass}
            placeholder="Ödeme yöntemi"
            value={form.payment_method}
            onChange={(e) => setForm({ ...form, payment_method: e.target.value })}
          />
          <input
            className={inputClass}
            placeholder="Açıklama"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <Button type="submit" disabled={busy}>
            {busy ? "Kaydediliyor…" : "Tahsilat Ekle"}
          </Button>
          <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
            Vazgeç
          </Button>
        </form>
      ) : (
        <div>
          <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
            + Tahsilat Ekle
          </Button>
        </div>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Masraflar ----------

export function ExpensesSection({
  project,
  expenses,
  locked,
}: {
  project: Project;
  expenses: Expense[];
  locked: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({
    category: "material" as ExpenseCategory,
    description: "",
    amount: "",
    expense_date: new Date().toISOString().slice(0, 10),
    supplier_name: "",
    invoice_no: "",
  });
  // Tahsilat/taşeron ödemesiyle SİMETRİK: anahtar form örneği başına
  // sabittir, yalnızca ONAYLANMIŞ bir gönderimden SONRA yenilenir --
  // aksi halde çift-tıkla/ağ-tekrarı koruması etkisiz kalırdı.
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/expenses`, {
        method: "POST",
        body: JSON.stringify({
          ...form,
          amount: Number(form.amount),
          currency: project.currency,
          idempotency_key: idempotencyKey,
        }),
      })
    );
    if (ok) {
      setIdempotencyKey(newIdempotencyKey());
      setForm({ ...form, description: "", amount: "", supplier_name: "", invoice_no: "" });
      setOpen(false);
    }
  }

  const validTotal = expenses.filter((e) => !e.voided_at).reduce((sum, e) => sum + e.amount, 0);

  return (
    <div className="flex flex-col gap-3">
      {expenses.length === 0 ? (
        <p className="text-text-muted">Henüz masraf kaydı yok.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase tracking-widest text-text-muted">
                <th className="pb-2">Tarih</th>
                <th className="pb-2">Kategori</th>
                <th className="pb-2">Açıklama</th>
                <th className="pb-2">Tedarikçi</th>
                <th className="pb-2 text-right">Tutar</th>
                <th className="pb-2"></th>
              </tr>
            </thead>
            <tbody>
              {expenses.map((e) => (
                <tr key={e.id} className={`border-t border-border ${e.voided_at ? "opacity-50" : ""}`}>
                  <td className="py-2 text-text-muted">
                    {new Date(e.expense_date).toLocaleDateString("tr-TR")}
                  </td>
                  <td className="py-2">{EXPENSE_CATEGORY_LABELS[e.category]}</td>
                  <td className="py-2">
                    {e.description}
                    {e.voided_at && <span className="ml-2 text-xs text-danger">İPTAL</span>}
                  </td>
                  <td className="py-2 text-text-muted">{e.supplier_name || "—"}</td>
                  <td className={`py-2 text-right ${e.voided_at ? "line-through" : "font-medium"}`}>
                    {formatMoney(e.amount, e.currency)}
                  </td>
                  <td className="py-2 text-right">
                    {!e.voided_at && !locked && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => {
                          const reason = prompt("İptal nedeni:") ?? "";
                          run(() =>
                            apiClient(`/api/v1/projects/${project.id}/expenses/${e.id}/void`, {
                              method: "POST",
                              body: JSON.stringify({ reason }),
                            })
                          );
                        }}
                        className="text-xs text-danger hover:underline"
                      >
                        İptal Et
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="flex items-center justify-between border-t border-border pt-2 text-sm">
        <span className="text-text-muted">Geçerli masraf toplamı</span>
        <span className="font-medium">{formatMoney(validTotal, project.currency)}</span>
      </div>
      <p className="text-xs text-text-muted">
        Taşeron ödemeleri buraya girilmez — çift sayımı önlemek için yalnızca Taşeronlar
        bölümünden kaydedilir.
      </p>

      {locked ? (
        <LockedNote project={project} />
      ) : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <select
            className={inputClass}
            value={form.category}
            onChange={(e) => setForm({ ...form, category: e.target.value as ExpenseCategory })}
            aria-label="Kategori"
          >
            {Object.entries(EXPENSE_CATEGORY_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
          <input
            className={inputClass}
            placeholder="Açıklama"
            required
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <input
            className={`${inputClass} w-36`}
            placeholder="Tutar"
            type="number"
            step="0.01"
            required
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <input
            className={inputClass}
            type="date"
            required
            value={form.expense_date}
            onChange={(e) => setForm({ ...form, expense_date: e.target.value })}
          />
          <input
            className={inputClass}
            placeholder="Tedarikçi"
            value={form.supplier_name}
            onChange={(e) => setForm({ ...form, supplier_name: e.target.value })}
          />
          <Button type="submit" disabled={busy}>
            {busy ? "Kaydediliyor…" : "Masraf Ekle"}
          </Button>
          <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
            Vazgeç
          </Button>
        </form>
      ) : (
        <div>
          <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
            + Masraf Ekle
          </Button>
        </div>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Faturalar ----------

export function InvoicesSection({
  project,
  invoices,
  locked,
}: {
  project: Project;
  invoices: ProjectInvoice[];
  locked: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({
    invoice_no: "",
    invoice_type: "sales",
    invoice_date: new Date().toISOString().slice(0, 10),
    due_date: "",
    amount: "",
    status: "draft",
  });

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/invoices`, {
        method: "POST",
        body: JSON.stringify({
          ...form,
          amount: Number(form.amount),
          currency: project.currency,
          due_date: form.due_date || null,
        }),
      })
    );
    if (ok) {
      setForm({ ...form, invoice_no: "", amount: "" });
      setOpen(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {invoices.length === 0 ? (
        <p className="text-text-muted">Henüz fatura kaydı yok.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase tracking-widest text-text-muted">
                <th className="pb-2">Fatura No</th>
                <th className="pb-2">Tip</th>
                <th className="pb-2">Tarih</th>
                <th className="pb-2">Vade</th>
                <th className="pb-2 text-right">Tutar</th>
                <th className="pb-2">Durum</th>
              </tr>
            </thead>
            <tbody>
              {invoices.map((inv) => (
                <tr key={inv.id} className="border-t border-border">
                  <td className="py-2 font-medium">{inv.invoice_no}</td>
                  <td className="py-2 text-text-muted">
                    {inv.invoice_type === "sales" ? "Satış" : "Alış"}
                  </td>
                  <td className="py-2 text-text-muted">
                    {new Date(inv.invoice_date).toLocaleDateString("tr-TR")}
                  </td>
                  <td className="py-2 text-text-muted">
                    {inv.due_date ? new Date(inv.due_date).toLocaleDateString("tr-TR") : "—"}
                  </td>
                  <td className="py-2 text-right font-medium">{formatMoney(inv.amount, inv.currency)}</td>
                  <td className="py-2">
                    {locked ? (
                      <Badge tone={INVOICE_TONE[inv.status]}>{INVOICE_STATUS_LABELS[inv.status]}</Badge>
                    ) : (
                      <select
                        className={`${inputClass} py-1 text-xs`}
                        value={inv.status}
                        disabled={busy}
                        onChange={(e) =>
                          run(() =>
                            apiClient(`/api/v1/projects/${project.id}/invoices/${inv.id}/status`, {
                              method: "PUT",
                              body: JSON.stringify({ status: e.target.value }),
                            })
                          )
                        }
                        aria-label="Fatura durumu"
                      >
                        {Object.entries(INVOICE_STATUS_LABELS).map(([k, label]) => (
                          <option key={k} value={k}>
                            {label}
                          </option>
                        ))}
                      </select>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {locked ? (
        <LockedNote project={project} />
      ) : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <input
            className={inputClass}
            placeholder="Fatura no"
            required
            value={form.invoice_no}
            onChange={(e) => setForm({ ...form, invoice_no: e.target.value })}
          />
          <select
            className={inputClass}
            value={form.invoice_type}
            onChange={(e) => setForm({ ...form, invoice_type: e.target.value })}
            aria-label="Fatura tipi"
          >
            <option value="sales">Satış</option>
            <option value="purchase">Alış</option>
          </select>
          <input
            className={`${inputClass} w-36`}
            placeholder="Tutar"
            type="number"
            step="0.01"
            required
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <input
            className={inputClass}
            type="date"
            required
            value={form.invoice_date}
            onChange={(e) => setForm({ ...form, invoice_date: e.target.value })}
          />
          <Button type="submit" disabled={busy}>
            {busy ? "Kaydediliyor…" : "Fatura Ekle"}
          </Button>
          <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
            Vazgeç
          </Button>
        </form>
      ) : (
        <div>
          <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
            + Fatura Ekle
          </Button>
        </div>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Taşeronlar ----------

export function SubcontractorsSection({
  project,
  subcontractors,
  payments,
  locked,
}: {
  project: Project;
  subcontractors: Subcontractor[];
  payments: SubcontractorPayment[];
  locked: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const [open, setOpen] = useState(false);
  const [payingFor, setPayingFor] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", company_name: "", work_description: "", contract_amount: "" });
  const [payForm, setPayForm] = useState({ amount: "", paid_date: new Date().toISOString().slice(0, 10), description: "" });
  // Anahtar TAŞERON BAŞINA tutulur (tek bir bölüm-geneli anahtar DEĞİL):
  // aksi halde taşeron A'ya ödeme yanıtı ağ hatasıyla kaybolduğunda, aynı
  // anahtarla taşeron B'ye yapılan bir sonraki ödeme, sunucu tarafında A'nın
  // kaydı sanılıp sessizce kaybolabiliyordu (bkz. denetim bulgusu; sunucu
  // tarafında da idempotency indeksini taşeron bazına indirdik, bu ekleme
  // savunmanın ikinci katmanıdır). ref kullanılır çünkü değer render'a
  // yansımaz, yalnızca istek gövdesinde taşınır.
  const payKeysRef = useRef<Record<string, string>>({});
  function payKeyFor(subId: string) {
    if (!payKeysRef.current[subId]) {
      payKeysRef.current[subId] = newIdempotencyKey();
    }
    return payKeysRef.current[subId];
  }

  async function addSub(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/subcontractors`, {
        method: "POST",
        body: JSON.stringify({
          ...form,
          contract_amount: Number(form.contract_amount),
          currency: project.currency,
        }),
      })
    );
    if (ok) {
      setForm({ name: "", company_name: "", work_description: "", contract_amount: "" });
      setOpen(false);
    }
  }

  async function addPayment(e: FormEvent, subId: string) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/subcontractors/${subId}/payments`, {
        method: "POST",
        body: JSON.stringify({
          amount: Number(payForm.amount),
          currency: project.currency,
          paid_date: payForm.paid_date,
          description: payForm.description,
          idempotency_key: payKeyFor(subId),
        }),
      })
    );
    if (ok) {
      payKeysRef.current[subId] = newIdempotencyKey();
      setPayForm({ ...payForm, amount: "", description: "" });
      setPayingFor(null);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      {subcontractors.length === 0 ? (
        <p className="text-text-muted">Henüz taşeron kaydı yok.</p>
      ) : (
        subcontractors.map((s) => {
          const subPayments = payments.filter((p) => p.subcontractor_id === s.id && !p.voided_at);
          return (
            <div key={s.id} className="rounded-md border border-border p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <span className="font-medium">{s.name}</span>
                  {s.company_name && <span className="ml-2 text-text-muted">{s.company_name}</span>}
                  {s.work_description && (
                    <div className="text-xs text-text-muted">{s.work_description}</div>
                  )}
                </div>
                <Badge tone={s.status === "completed" ? "success" : s.status === "cancelled" ? "danger" : "gold"}>
                  {SUBCONTRACTOR_STATUS_LABELS[s.status]}
                </Badge>
              </div>
              <div className="mt-2 grid grid-cols-3 gap-3 text-sm">
                <div>
                  <div className="text-xs uppercase tracking-widest text-text-muted">Sözleşme</div>
                  <div>{formatMoney(s.contract_amount, s.currency)}</div>
                </div>
                <div>
                  <div className="text-xs uppercase tracking-widest text-text-muted">Ödenen</div>
                  <div>{formatMoney(s.paid_amount, s.currency)}</div>
                </div>
                <div>
                  <div className="text-xs uppercase tracking-widest text-text-muted">Kalan</div>
                  <div className="font-medium">{formatMoney(s.remaining_amount, s.currency)}</div>
                </div>
              </div>

              {subPayments.length > 0 && (
                <ul className="mt-2 flex flex-col gap-0.5 border-t border-border pt-2 text-xs text-text-muted">
                  {subPayments.map((p) => (
                    <li key={p.id}>
                      {new Date(p.paid_date).toLocaleDateString("tr-TR")} ·{" "}
                      {formatMoney(p.amount, p.currency)}
                      {p.description && ` · ${p.description}`}
                    </li>
                  ))}
                </ul>
              )}

              {!locked && (
                <div className="mt-2">
                  {payingFor === s.id ? (
                    <form onSubmit={(e) => addPayment(e, s.id)} className="flex flex-wrap items-end gap-2">
                      <input
                        className={`${inputClass} w-32`}
                        placeholder="Tutar"
                        type="number"
                        step="0.01"
                        required
                        value={payForm.amount}
                        onChange={(e) => setPayForm({ ...payForm, amount: e.target.value })}
                      />
                      <input
                        className={inputClass}
                        type="date"
                        required
                        value={payForm.paid_date}
                        onChange={(e) => setPayForm({ ...payForm, paid_date: e.target.value })}
                      />
                      <input
                        className={inputClass}
                        placeholder="Açıklama"
                        value={payForm.description}
                        onChange={(e) => setPayForm({ ...payForm, description: e.target.value })}
                      />
                      <Button type="submit" disabled={busy}>
                        {busy ? "…" : "Ödeme Kaydet"}
                      </Button>
                      <Button type="button" variant="ghost" onClick={() => setPayingFor(null)}>
                        Vazgeç
                      </Button>
                    </form>
                  ) : (
                    <Button type="button" variant="secondary" onClick={() => setPayingFor(s.id)}>
                      + Ödeme Ekle
                    </Button>
                  )}
                </div>
              )}
            </div>
          );
        })
      )}

      {locked ? (
        <LockedNote project={project} />
      ) : open ? (
        <form onSubmit={addSub} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <input
            className={inputClass}
            placeholder="Taşeron adı"
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <input
            className={inputClass}
            placeholder="Firma"
            value={form.company_name}
            onChange={(e) => setForm({ ...form, company_name: e.target.value })}
          />
          <input
            className={inputClass}
            placeholder="Yapılan iş"
            value={form.work_description}
            onChange={(e) => setForm({ ...form, work_description: e.target.value })}
          />
          <input
            className={`${inputClass} w-36`}
            placeholder="Sözleşme bedeli"
            type="number"
            step="0.01"
            required
            value={form.contract_amount}
            onChange={(e) => setForm({ ...form, contract_amount: e.target.value })}
          />
          <Button type="submit" disabled={busy}>
            {busy ? "Ekleniyor…" : "Taşeron Ekle"}
          </Button>
          <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
            Vazgeç
          </Button>
        </form>
      ) : (
        <div>
          <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
            + Taşeron Ekle
          </Button>
        </div>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

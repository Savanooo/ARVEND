"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useRef, useState } from "react";

import { Section } from "@/components/ui/Accordion";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { Select } from "@/components/ui/Select";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney, istanbulDate } from "@/lib/format";
import { INVOICE_STATUS, PLAN_ITEM_STATUS, SUBCONTRACTOR_STATUS } from "@/lib/status";
import {
  EXPENSE_CATEGORY_LABELS,
  INVOICE_STATUS_LABELS,
  type BudgetLine,
  type ChangeOrder,
  type Collection,
  type Expense,
  type ExpenseCategory,
  type OrganizationCostCode,
  type PaymentPlanItem,
  type Project,
  type ProjectInvoice,
  type Subcontractor,
  type SubcontractorPayment,
} from "@/lib/types";

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
  currentContractValue,
  locked,
  canManage,
}: {
  project: Project;
  items: PaymentPlanItem[];
  plannedTotal: number;
  // Faz 8: karşılaştırma ana sözleşme (project.contract_amount) yerine
  // GÜNCEL proje bedeliyle yapılır -- onaylı ek işler mevcut ödeme
  // planında henüz karşılığı olmayan bir bakiye yaratabilir; bu artık
  // bir "hata" değil, doğru bir sinyaldir (bkz. spesifikasyon madde 25).
  currentContractValue: number;
  locked: boolean;
  // projects.finance.manage yoksa (salt okuma) yazma kontrolleri gizlenir.
  canManage: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const editable = !locked && canManage;
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
        <Table>
          <thead>
            <tr>
              <Th>Kalem</Th>
              <Th>Vade</Th>
              <Th className="text-right">Planlanan</Th>
              <Th className="text-right">Tahsil</Th>
              <Th className="text-right">Kalan</Th>
              <Th>Durum</Th>
              <Th className="w-10" />
            </tr>
          </thead>
          <tbody>
            {items.map((it) => (
              <Tr key={it.id}>
                <Td>
                  {it.name}
                  {it.percentage !== null && (
                    <span className="ml-1 text-xs text-text-muted">%{it.percentage}</span>
                  )}
                </Td>
                <Td className="text-text-muted">
                  {it.due_date ? new Date(it.due_date).toLocaleDateString("tr-TR") : "—"}
                </Td>
                <Td className="text-right">{formatMoney(it.planned_amount, project.currency)}</Td>
                <Td className="text-right">{formatMoney(it.collected_amount, project.currency)}</Td>
                <Td className="text-right">{formatMoney(it.remaining_amount, project.currency)}</Td>
                <Td>
                  <StatusBadge status={it.status} registry={PLAN_ITEM_STATUS} />
                </Td>
                <Td className="text-right">
                  {editable && it.status !== "cancelled" && (
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
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}

      <div className="flex items-center justify-between border-t border-border pt-2 text-sm">
        <span className="text-text-muted">Toplam plan tutarı</span>
        <span className="font-medium">{formatMoney(plannedTotal, project.currency)}</span>
      </div>
      {(() => {
        const diff = currentContractValue - plannedTotal;
        if (Math.abs(diff) < 0.005 || items.length === 0) return null;
        if (diff > 0) {
          return (
            <p className="text-xs text-gold">
              Ödeme planında {formatMoney(diff, project.currency)} planlanmamış bakiye bulunmaktadır
              (güncel proje bedeli {formatMoney(currentContractValue, project.currency)}).
            </p>
          );
        }
        return (
          <p className="text-xs text-text-muted">
            Plan toplamı güncel proje bedelinden ({formatMoney(currentContractValue, project.currency)}){" "}
            farklı — özel plan oluşturulmuş olabilir.
          </p>
        );
      })()}

      {locked ? (
        <LockedNote project={project} />
      ) : !canManage ? null : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Input
            placeholder="Kalem adı (ör. Peşinat)"
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <Input
            className="w-28"
            placeholder="Yüzde"
            type="number"
            step="0.01"
            value={form.percentage}
            onChange={(e) => setForm({ ...form, percentage: e.target.value, planned_amount: "" })}
          />
          <Input
            className="w-36"
            placeholder="veya tutar"
            type="number"
            step="0.01"
            value={form.planned_amount}
            onChange={(e) => setForm({ ...form, planned_amount: e.target.value, percentage: "" })}
          />
          <DateInput
            value={form.due_date}
            onChange={(e) => setForm({ ...form, due_date: e.target.value })}
          />
          <Button type="submit" loading={busy}>
            Ekle
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
  canManage,
}: {
  project: Project;
  collections: Collection[];
  planItems: PaymentPlanItem[];
  locked: boolean;
  // projects.finance.manage yoksa (salt okuma) yazma kontrolleri gizlenir.
  canManage: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const editable = !locked && canManage;
  const { askReason, dialog } = useReasonDialog();
  const [open, setOpen] = useState(false);
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);
  const [form, setForm] = useState({
    amount: "",
    received_date: istanbulDate(new Date()),
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
      {dialog}
      {collections.length === 0 ? (
        <p className="text-text-muted">Henüz tahsilat kaydı yok.</p>
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Tarih</Th>
              <Th>Açıklama</Th>
              <Th>Yöntem</Th>
              <Th className="text-right">Tutar</Th>
              <Th className="w-16" />
            </tr>
          </thead>
          <tbody>
            {collections.map((c) => (
              <Tr key={c.id} className={c.voided_at ? "opacity-50" : ""}>
                <Td className="text-text-muted">
                  {new Date(c.received_date).toLocaleDateString("tr-TR")}
                </Td>
                <Td>
                  {c.description || "—"}
                  {c.voided_at && (
                    <span className="ml-2 text-xs text-danger">
                      İPTAL{c.void_reason && ` · ${c.void_reason}`}
                    </span>
                  )}
                </Td>
                <Td className="text-text-muted">{c.payment_method || "—"}</Td>
                <Td className={`text-right ${c.voided_at ? "line-through" : "font-medium"}`}>
                  {formatMoney(c.amount, c.currency)}
                </Td>
                <Td className="text-right">
                  {!c.voided_at && editable && (
                    <button
                      type="button"
                      disabled={busy}
                      onClick={async () => {
                        const reason = await askReason({
                          title: "Tahsilatı İptal Et",
                          message: `${formatMoney(c.amount, c.currency)} tutarındaki tahsilat iptal edilecek; kayıt silinmez, İPTAL olarak işaretlenir.`,
                          label: "İptal nedeni",
                          confirmLabel: "İptal Et",
                          cancelLabel: "Vazgeç",
                          danger: true,
                        });
                        if (reason === null) return;
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
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}

      {locked ? (
        <LockedNote project={project} />
      ) : !canManage ? null : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Input
            className="w-36"
            placeholder="Tutar"
            type="number"
            step="0.01"
            required
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <DateInput
            required
            value={form.received_date}
            onChange={(e) => setForm({ ...form, received_date: e.target.value })}
          />
          <Select
            value={form.payment_plan_item_id}
            onChange={(e) => setForm({ ...form, payment_plan_item_id: e.target.value })}
            aria-label="Ödeme planı kalemi"
            className="w-44"
          >
            <option value="">Plan kalemi (opsiyonel)</option>
            {activePlanItems.map((i) => (
              <option key={i.id} value={i.id}>
                {i.name}
              </option>
            ))}
          </Select>
          <Input
            placeholder="Ödeme yöntemi"
            value={form.payment_method}
            onChange={(e) => setForm({ ...form, payment_method: e.target.value })}
          />
          <Input
            placeholder="Açıklama"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <Button type="submit" loading={busy}>
            Tahsilat Ekle
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

const emptyExpenseForm = () => ({
  category: "material" as ExpenseCategory,
  description: "",
  amount: "",
  expense_date: istanbulDate(new Date()),
  supplier_name: "",
  invoice_no: "",
  notes: "",
  change_order_id: "",
  // Maliyet Kontrolü (Sprint 2) eşlemesi -- ikisi de opsiyonel.
  cost_code_id: "",
  budget_line_id: "",
});

// Masraflar bölümü kendi <Section> sarmalayıcısını render eder: başlıktaki
// "+ Masraf Ekle" aksiyonu hem bölümü açmak hem formu göstermek zorunda
// olduğundan, bölümün açık/kapalı durumu ile form durumu AYNI bileşende
// yaşamalıdır. Form alanları, backend'in expenseRequest'inde ZATEN kabul
// ettiği alanların tamamıdır (bkz. handler/project_finance_handler.go) --
// yeni bir backend yeteneği eklenmedi. Para birimi kullanıcıya sorulmaz,
// projeninkinden gelir.
export function ExpensesSection({
  project,
  expenses,
  changeOrders,
  costCodes = [],
  budgetLines = [],
  locked,
  canManage,
}: {
  project: Project;
  expenses: Expense[];
  changeOrders: ChangeOrder[];
  // Maliyet Kontrolü (Sprint 2) -- opsiyonel: kullanıcının organization.
  // cost_codes.read/projects.budget.read izni yoksa (nadiren, bkz.
  // migration 0035 rol matrisi) boş dizi olarak gelir, seçiciler
  // gösterilmez ama masraf formu ÇALIŞMAYA devam eder.
  costCodes?: OrganizationCostCode[];
  budgetLines?: BudgetLine[];
  locked: boolean;
  // projects.finance.manage yoksa (salt okuma) yazma kontrolleri gizlenir.
  canManage: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const editable = !locked && canManage;
  const { askReason, dialog } = useReasonDialog();
  const [sectionOpen, setSectionOpen] = useState(false);
  const [formOpen, setFormOpen] = useState(false);
  const [form, setForm] = useState(emptyExpenseForm);
  // Tahsilat/taşeron ödemesiyle SİMETRİK: anahtar form örneği başına
  // sabittir, yalnızca ONAYLANMIŞ bir gönderimden SONRA yenilenir --
  // aksi halde çift-tıkla/ağ-tekrarı koruması etkisiz kalırdı.
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);

  // Ek iş bağlantısı için iptal/superseded olmayan ek işler sunulur --
  // backend aynı projeye ait her ek işi kabul eder, bu yalnızca anlamlı
  // seçenekleri gösteren bir UI daraltmasıdır.
  const linkableChangeOrders = changeOrders.filter(
    (co) => co.status !== "cancelled" && co.status !== "superseded"
  );
  const changeOrderNoById = new Map(changeOrders.map((co) => [co.id, co.change_order_no]));
  const activeCostCodes = costCodes.filter((c) => c.is_active);
  const costCodeById = new Map(costCodes.map((c) => [c.id, c]));

  function openForm() {
    setSectionOpen(true);
    setFormOpen(true);
  }

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
      setForm(emptyExpenseForm());
      setFormOpen(false);
    }
  }

  const validTotal = expenses.filter((e) => !e.voided_at).reduce((sum, e) => sum + e.amount, 0);

  return (
    <Section
      title="Masraflar"
      open={sectionOpen}
      onOpenChange={setSectionOpen}
      action={
        editable && (
          <Button type="button" onClick={openForm} disabled={busy}>
            + Masraf Ekle
          </Button>
        )
      }
    >
      <div className="flex flex-col gap-3">
        {dialog}
        {expenses.length === 0 ? (
          <p className="text-text-muted">Henüz masraf kaydı yok.</p>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Tarih</Th>
                <Th>Kategori</Th>
                <Th>Açıklama</Th>
                <Th>Tedarikçi</Th>
                <Th>Fatura No</Th>
                <Th className="text-right">Tutar</Th>
                <Th className="w-16" />
              </tr>
            </thead>
            <tbody>
              {expenses.map((e) => (
                <Tr key={e.id} className={e.voided_at ? "opacity-50" : ""}>
                  <Td className="text-text-muted">
                    {new Date(e.expense_date).toLocaleDateString("tr-TR")}
                  </Td>
                  <Td>{EXPENSE_CATEGORY_LABELS[e.category]}</Td>
                  <Td>
                    {e.description}
                    {e.change_order_id && (
                      <span className="ml-2 text-xs text-text-muted">
                        · {changeOrderNoById.get(e.change_order_id) ?? "Ek iş"}
                      </span>
                    )}
                    {e.cost_code_id && (
                      <span className="ml-2 text-xs text-text-muted">
                        · {costCodeById.get(e.cost_code_id)?.code ?? "Maliyet kodu"}
                      </span>
                    )}
                    {e.voided_at && (
                      <span className="ml-2 text-xs text-danger">
                        İPTAL{e.void_reason && ` · ${e.void_reason}`}
                      </span>
                    )}
                    {e.notes && <div className="text-xs text-text-muted">{e.notes}</div>}
                  </Td>
                  <Td className="text-text-muted">{e.supplier_name || "—"}</Td>
                  <Td className="text-text-muted">{e.invoice_no || "—"}</Td>
                  <Td className={`text-right ${e.voided_at ? "line-through" : "font-medium"}`}>
                    {formatMoney(e.amount, e.currency)}
                  </Td>
                  <Td className="text-right">
                    {!e.voided_at && editable && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={async () => {
                          const reason = await askReason({
                            title: "Masrafı İptal Et",
                            message: `${formatMoney(e.amount, e.currency)} tutarındaki masraf iptal edilecek; kayıt silinmez, İPTAL olarak işaretlenir.`,
                            label: "İptal nedeni",
                            confirmLabel: "İptal Et",
                            cancelLabel: "Vazgeç",
                            danger: true,
                          });
                          if (reason === null) return;
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
                  </Td>
                </Tr>
              ))}
            </tbody>
          </Table>
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
        ) : (
          formOpen && (
            <form onSubmit={submit} className="flex flex-col gap-3 border-t border-border pt-3">
              <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
                <Select
                  label="Kategori"
                  name="expense_category"
                  value={form.category}
                  onChange={(e) => setForm({ ...form, category: e.target.value as ExpenseCategory })}
                >
                  {Object.entries(EXPENSE_CATEGORY_LABELS).map(([k, label]) => (
                    <option key={k} value={k}>
                      {label}
                    </option>
                  ))}
                </Select>
                <Input
                  label={`Tutar (${project.currency})`}
                  name="expense_amount"
                  type="number"
                  step="0.01"
                  min="0"
                  required
                  value={form.amount}
                  onChange={(e) => setForm({ ...form, amount: e.target.value })}
                />
                <DateInput
                  label="Tarih"
                  name="expense_date"
                  required
                  value={form.expense_date}
                  onChange={(e) => setForm({ ...form, expense_date: e.target.value })}
                />
                <Input
                  label="Tedarikçi"
                  name="expense_supplier"
                  value={form.supplier_name}
                  onChange={(e) => setForm({ ...form, supplier_name: e.target.value })}
                />
                <Input
                  label="Fatura No"
                  name="expense_invoice_no"
                  value={form.invoice_no}
                  onChange={(e) => setForm({ ...form, invoice_no: e.target.value })}
                />
                {linkableChangeOrders.length > 0 && (
                  <Select
                    label="Ek İş (opsiyonel)"
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
                {budgetLines.length > 0 && (
                  <Select
                    label="Bütçe Kalemi (opsiyonel)"
                    name="expense_budget_line"
                    value={form.budget_line_id}
                    onChange={(e) => {
                      const line = budgetLines.find((l) => l.id === e.target.value);
                      setForm({
                        ...form,
                        budget_line_id: e.target.value,
                        // Maliyet kodu, seçilen bütçe kaleminden OTOMATİK
                        // doldurulur (spec: "budget-line seçilince cost code
                        // otomatik doldurulmalı") -- backend zaten aynı
                        // kuralı otoriter olarak uygular, bu yalnızca UX.
                        cost_code_id: line ? line.cost_code_id : form.cost_code_id,
                      });
                    }}
                  >
                    <option value="">Bağlı değil (bütçe dışı)</option>
                    {budgetLines.map((l) => (
                      <option key={l.id} value={l.id}>
                        {l.description} ({l.cost_code_code})
                      </option>
                    ))}
                  </Select>
                )}
                {activeCostCodes.length > 0 && (
                  <Select
                    label="Maliyet Kodu (opsiyonel)"
                    name="expense_cost_code"
                    value={form.cost_code_id}
                    disabled={!!form.budget_line_id}
                    onChange={(e) => setForm({ ...form, cost_code_id: e.target.value })}
                  >
                    <option value="">Yok</option>
                    {activeCostCodes.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.code} — {c.name}
                      </option>
                    ))}
                  </Select>
                )}
                <div className="col-span-2">
                  <Input
                    label="Açıklama"
                    name="expense_description"
                    required
                    value={form.description}
                    onChange={(e) => setForm({ ...form, description: e.target.value })}
                  />
                </div>
              </div>
              <Textarea
                label="Not"
                name="expense_notes"
                className="min-h-16"
                value={form.notes}
                onChange={(e) => setForm({ ...form, notes: e.target.value })}
              />
              <div className="flex gap-2">
                <Button type="submit" loading={busy}>
                  Kaydet
                </Button>
                <Button type="button" variant="ghost" onClick={() => setFormOpen(false)}>
                  Vazgeç
                </Button>
              </div>
            </form>
          )
        )}
        {error && <p className="text-xs text-danger">{error}</p>}
      </div>
    </Section>
  );
}

// ---------- Faturalar ----------

export function InvoicesSection({
  project,
  invoices,
  locked,
  canManage,
}: {
  project: Project;
  invoices: ProjectInvoice[];
  locked: boolean;
  // projects.finance.manage yoksa (salt okuma) yazma kontrolleri gizlenir.
  canManage: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const editable = !locked && canManage;
  const { confirm, dialog } = useConfirmDialog();
  const [open, setOpen] = useState(false);

  // Satış faturası "ödendi" yapılırken tahsilat da sorulur: proje özetinin
  // tahsilatı ve kârı tahsilat kayıtlarından hesaplanır, faturanın durumu
  // para girişi sayılmaz (sahada 2026-10). Tahsilat ayrıca girildiyse "hayır"
  // -- para iki kez sayılmaz. Fatura "ödendi"den çıkarsa backend bağlı
  // tahsilatı iptal eder.
  async function changeStatus(inv: ProjectInvoice, status: string) {
    let record: boolean | undefined;
    if (status === "paid" && inv.invoice_type === "sales") {
      record = await confirm({
        title: "Fatura ödendi",
        message: `${inv.invoice_no} ödendi olarak işaretlenecek. Proje özetindeki tahsilat ve kâr, tahsilat kayıtlarından hesaplanır. ${formatMoney(inv.amount, inv.currency)} tahsilat olarak da kaydedilsin mi?`,
        confirmLabel: "Tahsilat da kaydet",
        cancelLabel: "Hayır, tahsilatı zaten girdim",
      });
    }
    await run(() =>
      apiClient(`/api/v1/projects/${project.id}/invoices/${inv.id}/status`, {
        method: "PUT",
        body: JSON.stringify(
          record === undefined ? { status } : { status, record_collection: record }
        ),
      })
    );
  }

  const [form, setForm] = useState({
    invoice_no: "",
    invoice_type: "sales",
    invoice_date: istanbulDate(new Date()),
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
      {dialog}
      {invoices.length === 0 ? (
        <p className="text-text-muted">Henüz fatura kaydı yok.</p>
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Fatura No</Th>
              <Th>Tip</Th>
              <Th>Tarih</Th>
              <Th>Vade</Th>
              <Th className="text-right">Tutar</Th>
              <Th>Durum</Th>
            </tr>
          </thead>
          <tbody>
            {invoices.map((inv) => (
              <Tr key={inv.id}>
                <Td className="font-medium">{inv.invoice_no}</Td>
                <Td className="text-text-muted">{inv.invoice_type === "sales" ? "Satış" : "Alış"}</Td>
                <Td className="text-text-muted">
                  {new Date(inv.invoice_date).toLocaleDateString("tr-TR")}
                </Td>
                <Td className="text-text-muted">
                  {inv.due_date ? new Date(inv.due_date).toLocaleDateString("tr-TR") : "—"}
                </Td>
                <Td className="text-right font-medium">{formatMoney(inv.amount, inv.currency)}</Td>
                <Td>
                  {!editable ? (
                    <StatusBadge status={inv.status} registry={INVOICE_STATUS} />
                  ) : (
                    <Select
                      value={inv.status}
                      disabled={busy}
                      onChange={(e) => changeStatus(inv, e.target.value)}
                      aria-label="Fatura durumu"
                      className="py-1 text-xs"
                    >
                      {Object.entries(INVOICE_STATUS_LABELS).map(([k, label]) => (
                        <option key={k} value={k}>
                          {label}
                        </option>
                      ))}
                    </Select>
                  )}
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}

      {locked ? (
        <LockedNote project={project} />
      ) : !canManage ? null : open ? (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Input
            placeholder="Fatura no"
            required
            value={form.invoice_no}
            onChange={(e) => setForm({ ...form, invoice_no: e.target.value })}
          />
          <Select
            value={form.invoice_type}
            onChange={(e) => setForm({ ...form, invoice_type: e.target.value })}
            aria-label="Fatura tipi"
            className="w-32"
          >
            <option value="sales">Satış</option>
            <option value="purchase">Alış</option>
          </Select>
          <Input
            className="w-36"
            placeholder="Tutar"
            type="number"
            step="0.01"
            required
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <DateInput
            required
            value={form.invoice_date}
            onChange={(e) => setForm({ ...form, invoice_date: e.target.value })}
          />
          <Button type="submit" loading={busy}>
            Fatura Ekle
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
  canManage,
}: {
  project: Project;
  subcontractors: Subcontractor[];
  payments: SubcontractorPayment[];
  locked: boolean;
  // projects.finance.manage yoksa (salt okuma) yazma kontrolleri gizlenir.
  canManage: boolean;
}) {
  const { busy, error, run } = useFinanceAction(locked);
  const editable = !locked && canManage;
  const [open, setOpen] = useState(false);
  const [payingFor, setPayingFor] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", company_name: "", work_description: "", contract_amount: "" });
  const [payForm, setPayForm] = useState({ amount: "", paid_date: istanbulDate(new Date()), description: "" });
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
                <StatusBadge status={s.status} registry={SUBCONTRACTOR_STATUS} />
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

              {editable && (
                <div className="mt-2">
                  {payingFor === s.id ? (
                    <form onSubmit={(e) => addPayment(e, s.id)} className="flex flex-wrap items-end gap-2">
                      <Input
                        className="w-32"
                        placeholder="Tutar"
                        type="number"
                        step="0.01"
                        required
                        value={payForm.amount}
                        onChange={(e) => setPayForm({ ...payForm, amount: e.target.value })}
                      />
                      <DateInput
                        required
                        value={payForm.paid_date}
                        onChange={(e) => setPayForm({ ...payForm, paid_date: e.target.value })}
                      />
                      <Input
                        placeholder="Açıklama"
                        value={payForm.description}
                        onChange={(e) => setPayForm({ ...payForm, description: e.target.value })}
                      />
                      <Button type="submit" loading={busy}>
                        Ödeme Kaydet
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
      ) : !canManage ? null : open ? (
        <form onSubmit={addSub} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Input
            placeholder="Taşeron adı"
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <Input
            placeholder="Firma"
            value={form.company_name}
            onChange={(e) => setForm({ ...form, company_name: e.target.value })}
          />
          <Input
            placeholder="Yapılan iş"
            value={form.work_description}
            onChange={(e) => setForm({ ...form, work_description: e.target.value })}
          />
          <Input
            className="w-36"
            placeholder="Sözleşme bedeli"
            type="number"
            step="0.01"
            required
            value={form.contract_amount}
            onChange={(e) => setForm({ ...form, contract_amount: e.target.value })}
          />
          <Button type="submit" loading={busy}>
            Taşeron Ekle
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

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useRef, useState } from "react";

import { Section } from "@/components/ui/Accordion";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { Input } from "@/components/ui/Input";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { Select } from "@/components/ui/Select";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Textarea } from "@/components/ui/Textarea";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import {
  buildChangeItems,
  CHANGE_TYPE_LABELS,
  changeItemDraftFromItem,
  changeOrderActions,
  emptyChangeItemDraft,
  round2,
  signedChangeOrderAmount,
  subcontractActions,
  SUBCONTRACT_CHANGE_ORDER_STATUS,
  type ChangeItemDraft,
  type Subcontract,
  type SubcontractChangeOrder,
  type SubcontractChangeOrderItem,
  type SubcontractChangeType,
  type SubcontractPerms,
} from "@/lib/subcontracts";
import type { BudgetLine, OrganizationCostCode, Project, WBSNode } from "@/lib/types";

import {
  BudgetLineSelect,
  costCodeLabel,
  CostCodeSelect,
  Field,
  formatTs,
  inputClass,
  StatusPill,
  useSubcontractAction,
  WbsSelect,
} from "../shared";

// Taşeron değişiklik emri (ek iş / kesinti, MALİYET tarafı) -- mobil
// subcontract_change_order_detail/form ekranlarının karşılığı. Proje
// düzeyindeki müşteri "Ek İşler"i (gelir tarafı) İLE KARIŞTIRILMAMALI.
// Oluştur/düzenle/gönder/iptal subcontracts.manage; onay/red
// subcontracts.approve (değişiklik emrinin kendi izni yok). Yalnızca
// ONAYLI emir sözleşmenin güncel değerini ve taahhüdünü değiştirir.

type ChangeOrderDetail = { subcontract_change_order: SubcontractChangeOrder; items: SubcontractChangeOrderItem[] };

function changeOrderUrl(projectId: string, changeOrderId: string) {
  return `/api/v1/projects/${projectId}/subcontract-change-orders/${changeOrderId}`;
}

export function ChangeOrdersPanel({
  project,
  subcontract,
  changeOrders,
  costCodes,
  budgetLines,
  wbsNodes,
  perms,
  locked,
  focusChangeOrderId,
}: {
  project: Project;
  subcontract: Subcontract;
  changeOrders: SubcontractChangeOrder[] | null;
  costCodes: OrganizationCostCode[] | null;
  budgetLines: BudgetLine[] | null;
  wbsNodes: WBSNode[] | null;
  perms: SubcontractPerms;
  locked: boolean;
  focusChangeOrderId: string | null;
}) {
  const [form, setForm] = useState<null | { changeOrder?: SubcontractChangeOrder; items?: SubcontractChangeOrderItem[] }>(
    null
  );
  const canAdd = subcontractActions(subcontract.status, perms, locked).addChangeOrder;

  return (
    <Section title="Değişiklik Emirleri (Ek İş / Kesinti)" defaultOpen>
      {changeOrders === null ? (
        <p className="text-text-muted">Değişiklik emirleri yüklenemedi.</p>
      ) : (
        <div className="flex flex-col gap-3">
          {changeOrders.length === 0 && !form && <p className="text-text-muted">Henüz değişiklik emri yok.</p>}
          {changeOrders.map((co) => (
            <ChangeOrderCard
              key={co.id}
              project={project}
              subcontract={subcontract}
              changeOrder={co}
              costCodes={costCodes}
              budgetLines={budgetLines}
              perms={perms}
              locked={locked}
              focused={co.id === focusChangeOrderId}
              onEdit={(items) => setForm({ changeOrder: co, items })}
            />
          ))}
          {form ? (
            <ChangeOrderForm
              key={form.changeOrder?.id ?? "new"}
              project={project}
              subcontract={subcontract}
              costCodes={costCodes}
              budgetLines={budgetLines}
              wbsNodes={wbsNodes}
              initial={form.changeOrder && form.items ? { changeOrder: form.changeOrder, items: form.items } : null}
              locked={locked}
              onClose={() => setForm(null)}
            />
          ) : (
            canAdd && (
              <div>
                <Button type="button" variant="secondary" onClick={() => setForm({})}>
                  + Değişiklik Emri Ekle
                </Button>
              </div>
            )
          )}
          {subcontract.status !== "active" && subcontract.status !== "draft" && (
            <p className="text-xs text-text-muted">
              Değişiklik emri yalnızca aktif sözleşmeye girilebilir ve yalnızca aktif sözleşmede onaylanabilir.
            </p>
          )}
          {subcontract.status === "draft" && (
            <p className="text-xs text-text-muted">
              Taslak sözleşmede kalemler doğrudan düzenlenir; değişiklik emri aktifleştirmeden sonra girilir.
            </p>
          )}
        </div>
      )}
    </Section>
  );
}

// ---------- Değişiklik emri kartı ----------

function ChangeOrderCard({
  project,
  subcontract,
  changeOrder,
  costCodes,
  budgetLines,
  perms,
  locked,
  focused,
  onEdit,
}: {
  project: Project;
  subcontract: Subcontract;
  changeOrder: SubcontractChangeOrder;
  costCodes: OrganizationCostCode[] | null;
  budgetLines: BudgetLine[] | null;
  perms: SubcontractPerms;
  locked: boolean;
  focused: boolean;
  onEdit: (items: SubcontractChangeOrderItem[]) => void;
}) {
  const co = changeOrder;
  const currency = subcontract.currency;
  const { busy, error, setError, run } = useSubcontractAction(locked);
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const { askReason, dialog: reasonDialog } = useReasonDialog();
  const [expanded, setExpanded] = useState(focused);
  // Kalemler emrin updated_at'iyle anahtarlanır (bkz. ClaimsPanel).
  const [loaded, setLoaded] = useState<{ at: string; items: SubcontractChangeOrderItem[] } | null>(null);
  const items = loaded && loaded.at === co.updated_at ? loaded.items : null;
  const ref = useRef<HTMLDivElement>(null);
  const actions = changeOrderActions(co.status, subcontract.status, perms, locked);
  const url = changeOrderUrl(project.id, co.id);
  const signed = signedChangeOrderAmount(co);

  const costCodeById = new Map((costCodes ?? []).map((c) => [c.id, c]));
  const budgetLineById = new Map((budgetLines ?? []).map((l) => [l.id, l]));

  useEffect(() => {
    if (focused) ref.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [focused]);

  useEffect(() => {
    if (!expanded || items) return;
    const at = co.updated_at;
    let stale = false;
    apiClient<ChangeOrderDetail>(url)
      .then(
        (d) => d.items,
        () => [] as SubcontractChangeOrderItem[]
      )
      .then((list) => {
        if (!stale) setLoaded({ at, items: list });
      });
    return () => {
      stale = true;
    };
  }, [expanded, items, url, co.updated_at]);

  async function submit() {
    if (!(await confirm({ title: "Değişiklik Emrini Gönder", message: `${co.number} onay için gönderilsin mi?`, confirmLabel: "Gönder" })))
      return;
    if (await run(() => apiClient(`${url}/submit`, { method: "POST" }))) toast.success(`${co.number} onaya gönderildi.`);
  }
  async function approve() {
    if (
      !(await confirm({
        title: "Değişiklik Emrini Onayla",
        message: `${co.number} onaylansın mı? Onay, sözleşmenin güncel değerini ve taahhüt kaydını hemen değiştirir.`,
        confirmLabel: "Onayla",
      }))
    )
      return;
    if (await run(() => apiClient(`${url}/approve`, { method: "POST" }))) toast.success(`${co.number} onaylandı.`);
  }
  async function reject() {
    const reason = await askReason({
      title: "Değişiklik Emrini Reddet",
      message: `${co.number} reddedilecek.`,
      label: "Red gerekçesi",
      confirmLabel: "Reddet",
      danger: true,
      required: true,
    });
    if (reason === null) return;
    if (await run(() => apiClient(`${url}/reject`, { method: "POST", body: JSON.stringify({ reason }) })))
      toast.success("Değişiklik emri reddedildi.");
  }
  async function cancel() {
    if (
      !(await confirm({
        title: "Değişiklik Emrini İptal Et",
        message: `${co.number} iptal edilsin mi? Bu işlem geri alınamaz.`,
        confirmLabel: "İptal Et",
        danger: true,
      }))
    )
      return;
    if (await run(() => apiClient(`${url}/cancel`, { method: "POST" }))) toast.success("Değişiklik emri iptal edildi.");
  }
  async function edit() {
    setError(null);
    try {
      const d = items ?? (await apiClient<ChangeOrderDetail>(url)).items;
      onEdit(d);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    }
  }

  const anyAction = actions.edit || actions.submit || actions.cancel || actions.approve || actions.reject;

  return (
    <div
      ref={ref}
      id={`degisiklik-${co.id}`}
      className={`rounded-md border p-3 ${focused ? "border-gold" : "border-border"}`}
    >
      <button
        type="button"
        className="flex w-full flex-wrap items-center justify-between gap-2 text-left"
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}
      >
        <div>
          <span className="font-medium">{co.number}</span>
          <span className="ml-2">{co.title}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className={`font-medium ${co.change_type === "deduction" ? "text-danger" : "text-success"}`}>
            {formatSignedMoney(signed, currency)}
          </span>
          <StatusPill registry={SUBCONTRACT_CHANGE_ORDER_STATUS} status={co.status} />
        </div>
      </button>
      {expanded && (
        <div className="mt-3 flex flex-col gap-4 border-t border-border pt-3 text-sm">
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <Field label="Tür" value={CHANGE_TYPE_LABELS[co.change_type] ?? co.change_type} />
            <Field label="Toplam Tutar" value={formatMoney(co.amount, currency)} />
            <Field label="Gönderildi" value={formatTs(co.requested_at)} />
            <Field
              label={co.status === "rejected" ? "Reddedildi" : co.status === "cancelled" ? "İptal" : "Onaylandı"}
              value={formatTs(co.status === "rejected" ? co.rejected_at : co.status === "cancelled" ? co.cancelled_at : co.approved_at)}
            />
          </div>
          {co.description && <Field label="Açıklama" value={<span className="whitespace-pre-line">{co.description}</span>} />}
          {co.reason && <Field label="Gerekçe" value={co.reason} />}
          {co.status === "rejected" && co.rejection_reason && (
            <p className="text-xs text-danger">Red gerekçesi: {co.rejection_reason}</p>
          )}

          {items === null ? (
            <p className="text-xs text-text-muted">Kalemler yükleniyor…</p>
          ) : items.length === 0 ? (
            <p className="text-xs text-text-muted">Kalem yok.</p>
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Açıklama</Th>
                  <Th>Maliyet Kodu</Th>
                  <Th>Bütçe Kalemi</Th>
                  <Th className="text-right">Tutar</Th>
                </tr>
              </thead>
              <tbody>
                {items.map((it) => {
                  const cc = costCodeById.get(it.cost_code_id);
                  const bl = it.budget_line_id ? budgetLineById.get(it.budget_line_id) : undefined;
                  return (
                    <Tr key={it.id}>
                      <Td>{it.description}</Td>
                      <Td className="text-text-muted">{cc ? costCodeLabel(cc) : "—"}</Td>
                      <Td className="text-text-muted">{bl ? bl.description : it.budget_line_id ? "Bağlı" : "—"}</Td>
                      <Td className="text-right">{formatMoney(it.amount, currency)}</Td>
                    </Tr>
                  );
                })}
              </tbody>
            </Table>
          )}

          {anyAction && (
            <div className="flex flex-wrap gap-2">
              {actions.edit && (
                <Button type="button" variant="secondary" disabled={busy} onClick={edit}>
                  Düzenle
                </Button>
              )}
              {actions.submit && (
                <Button type="button" disabled={busy} onClick={submit}>
                  Gönder
                </Button>
              )}
              {actions.approve && (
                <Button type="button" disabled={busy} onClick={approve}>
                  Onayla
                </Button>
              )}
              {actions.reject && (
                <Button type="button" variant="danger" disabled={busy} onClick={reject}>
                  Reddet
                </Button>
              )}
              {actions.cancel && (
                <Button type="button" variant="danger" disabled={busy} onClick={cancel}>
                  İptal Et
                </Button>
              )}
            </div>
          )}
          {co.status === "submitted" && subcontract.status !== "active" && perms.canApprove && !locked && (
            <p className="text-xs text-text-muted">
              Sözleşme aktif olmadığı için bu değişiklik emri onaylanamaz; reddedin ya da iptal edin.
            </p>
          )}
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
      )}
      {dialog}
      {reasonDialog}
    </div>
  );
}

// ---------- Değişiklik emri formu (oluştur / taslağı düzenle) ----------

function ChangeOrderForm({
  project,
  subcontract,
  costCodes,
  budgetLines,
  wbsNodes,
  initial,
  locked,
  onClose,
}: {
  project: Project;
  subcontract: Subcontract;
  costCodes: OrganizationCostCode[] | null;
  budgetLines: BudgetLine[] | null;
  wbsNodes: WBSNode[] | null;
  initial: { changeOrder: SubcontractChangeOrder; items: SubcontractChangeOrderItem[] } | null;
  locked: boolean;
  onClose: () => void;
}) {
  const router = useRouter();
  const toast = useToast();
  const currency = subcontract.currency;
  const [form, setForm] = useState({
    title: initial?.changeOrder.title ?? "",
    description: initial?.changeOrder.description ?? "",
    change_type: (initial?.changeOrder.change_type ?? "addition") as SubcontractChangeType,
    reason: initial?.changeOrder.reason ?? "",
  });
  // PUT kalemleri BÜTÜNÜYLE yeniden yazar: mevcut kalemlerin WBS/bütçe
  // kalemi dahil her alanı taslağa yüklenir ve geri gönderilir.
  const [drafts, setDrafts] = useState<ChangeItemDraft[]>(() =>
    initial && initial.items.length > 0 ? initial.items.map(changeItemDraftFromItem) : [emptyChangeItemDraft()]
  );
  const [rowErrors, setRowErrors] = useState<Record<number, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  function setDraft(i: number, patch: Partial<ChangeItemDraft>) {
    setDrafts(drafts.map((d, j) => (j === i ? { ...d, ...patch } : d)));
  }

  const preview = buildChangeItems(drafts);
  const total = round2(preview.items.reduce((s, it) => s + it.amount, 0));

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (locked) return;
    setError(null);
    if (!form.title.trim()) return setError("Başlık gerekli.");
    const built = buildChangeItems(drafts);
    setRowErrors(built.errors);
    if (Object.keys(built.errors).length > 0) return setError("Kalemlerdeki hataları düzeltin.");
    if (built.items.length === 0) return setError("En az bir geçerli kalem girin (maliyet kodu, açıklama, tutar > 0).");

    setSaving(true);
    try {
      const body = JSON.stringify({
        title: form.title.trim(),
        description: form.description.trim(),
        change_type: form.change_type,
        reason: form.reason.trim(),
        items: built.items,
      });
      if (initial) {
        await apiClient(changeOrderUrl(project.id, initial.changeOrder.id), { method: "PUT", body });
        toast.success("Değişiklik emri güncellendi.");
      } else {
        await apiClient(`/api/v1/projects/${project.id}/subcontracts/${subcontract.id}/change-orders`, {
          method: "POST",
          body,
        });
        toast.success("Değişiklik emri oluşturuldu (taslak).");
      }
      router.refresh();
      onClose();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4 rounded-md border border-gold/60 p-3">
      <p className="text-sm font-semibold">
        {initial ? `${initial.changeOrder.number} — Düzenle` : "Yeni Değişiklik Emri"}
      </p>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <Input label="Başlık" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} />
        <Select
          label="Tür"
          value={form.change_type}
          onChange={(e) => setForm({ ...form, change_type: e.target.value as SubcontractChangeType })}
        >
          <option value="addition">{CHANGE_TYPE_LABELS.addition}</option>
          <option value="deduction">{CHANGE_TYPE_LABELS.deduction}</option>
        </Select>
      </div>
      <Textarea
        label="Açıklama (opsiyonel)"
        value={form.description}
        onChange={(e) => setForm({ ...form, description: e.target.value })}
      />
      <Input
        label="Gerekçe (opsiyonel)"
        value={form.reason}
        onChange={(e) => setForm({ ...form, reason: e.target.value })}
      />

      <div className="flex flex-col gap-2">
        <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">Kalemler</span>
        {costCodes === null && (
          <p className="text-xs text-danger">
            Maliyet kodu listesini görme yetkiniz yok; her kalem için maliyet kodu zorunludur.
          </p>
        )}
        {drafts.map((d, i) => (
          <div key={i} className="flex flex-col gap-2 rounded-md border border-border p-3">
            <div className="grid grid-cols-12 gap-2">
              <input
                className={`${inputClass} col-span-12 md:col-span-5`}
                placeholder="Açıklama"
                value={d.description}
                onChange={(e) => setDraft(i, { description: e.target.value })}
              />
              <CostCodeSelect
                className="col-span-12 md:col-span-4"
                value={d.cost_code_id}
                onChange={(v) => setDraft(i, { cost_code_id: v })}
                costCodes={costCodes ?? []}
              />
              <input
                className={`${inputClass} col-span-9 text-right md:col-span-2`}
                inputMode="decimal"
                placeholder={`Tutar (${currency})`}
                value={d.amount}
                onChange={(e) => setDraft(i, { amount: e.target.value })}
              />
              <button
                type="button"
                className="col-span-3 text-xs text-danger disabled:opacity-40 md:col-span-1"
                disabled={drafts.length <= 1}
                onClick={() => setDrafts(drafts.filter((_, j) => j !== i))}
              >
                Sil
              </button>
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
        ))}
        <div className="flex flex-wrap items-center justify-between gap-2">
          <Button type="button" variant="ghost" onClick={() => setDrafts([...drafts, emptyChangeItemDraft()])}>
            + Kalem Ekle
          </Button>
          <span className="text-sm">
            Toplam:{" "}
            <span className={`font-semibold ${form.change_type === "deduction" ? "text-danger" : "text-success"}`}>
              {formatSignedMoney(form.change_type === "deduction" ? -total : total, currency)}
            </span>
          </span>
        </div>
        <p className="text-xs text-text-muted">
          Kalemler maliyet kodu (ve bütçe kalemi) grubuna bağlanır; onaylı ek iş o gruptaki kalemlerin hakediş sınırını
          yükseltir, kesinti düşürür.
        </p>
      </div>

      {error && <p className="text-sm text-danger">{error}</p>}
      <div className="flex gap-2">
        <Button type="submit" loading={saving}>
          {initial ? "Kaydet" : "Değişiklik Emri Oluştur"}
        </Button>
        <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>
          Vazgeç
        </Button>
      </div>
      <p className="text-xs text-text-muted">
        Kayıt taslak olarak oluşur; onay için ayrıca &quot;Gönder&quot; gerekir. Yalnızca onaylanan emir sözleşme tutarını
        değiştirir.
      </p>
    </form>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useState } from "react";

import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { Select } from "@/components/ui/Select";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Tabs } from "@/components/ui/Tabs";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Textarea } from "@/components/ui/Textarea";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney, istanbulDate } from "@/lib/format";
import { PURCHASE_ORDER_STATUS, PURCHASE_REQUEST_STATUS, RFQ_STATUS } from "@/lib/status";
import type {
  BidComparisonRow,
  BudgetLine,
  Commitment,
  OrganizationCostCode,
  Project,
  PurchaseOrder,
  PurchaseOrderItem,
  PurchaseRequest,
  PurchaseRequestItem,
  RFQ,
  RFQItem,
  RFQSupplier,
  Supplier,
  SupplierQuotation,
  WBSNode,
} from "@/lib/types";

// ARVEND V2 — Sprint 4: Procurement Foundation. Purchase Request -> RFQ
// (PR kaleminden SNAPSHOT alır) -> Supplier Quotation (manuel girilir) ->
// Award (kazanan SEÇİLİR, sistem OTOMATİK seçmez) -> Purchase Order
// (onayda Cost Control'e commitment oluşturur). Contract/Ek İşler (Sprint
// 3, GELİR tarafı, Finans sekmesinde) İLE KARIŞTIRILMAMALI — bu, MALİYET
// (tedarikçi) tarafıdır.
//
// Alt sekmeler CostControlWorkspace'in İÇ ControlledTabs deseninden
// KASITLI olarak SAPAR: "RFQ" sekmesindeki bir kaydın "Karşılaştır"
// düğmesi, "Teklif Karşılaştırma" sekmesine SEÇİLİ bir RFQ ile
// PROGRAMATİK olarak atlamalı -- ControlledTabs bunu dışarıdan
// kontrol etmeye izin vermez, bu yüzden aktif-sekme durumu burada
// (PurchasingWorkspace'te) AÇIKÇA tutulur ve alt-sekmeler arası
// paylaşılır (aynı alt seviye Tabs bileşeni kullanılır).

const inputClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text placeholder:text-text-muted/60 outline-none focus:border-gold";

function usePurchasingAction(locked: boolean) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function run<T>(fn: () => Promise<T>): Promise<T | null> {
    if (locked) return null;
    setBusy(true);
    setError(null);
    try {
      const out = await fn();
      router.refresh();
      return out;
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      return null;
    } finally {
      setBusy(false);
    }
  }
  return { busy, error, run };
}

function formatDate(d: string | null | undefined) {
  return d ? new Date(d).toLocaleDateString("tr-TR") : "—";
}

function costCodeLabel(c: OrganizationCostCode) {
  return `${c.code} — ${c.name}`;
}

// ---------- Purchase Request kalem editörü ----------

type PRItemDraft = {
  wbs_node_id: string; cost_code_id: string; budget_line_id: string;
  description: string; quantity: string; unit: string; estimated_unit_cost: string; estimated_total: string;
};
const emptyPRItem = (): PRItemDraft => ({
  wbs_node_id: "", cost_code_id: "", budget_line_id: "", description: "", quantity: "1", unit: "adet",
  estimated_unit_cost: "", estimated_total: "",
});

function PRItemsEditor({
  items, setItems, costCodes, wbsNodes, budgetLines,
}: {
  items: PRItemDraft[]; setItems: (v: PRItemDraft[]) => void;
  costCodes: OrganizationCostCode[]; wbsNodes: WBSNode[]; budgetLines: BudgetLine[];
}) {
  return (
    <div className="flex flex-col gap-2">
      {items.map((it, i) => (
        <div key={i} className="grid grid-cols-12 gap-2 rounded-md border border-border p-2">
          <input
            className={`${inputClass} col-span-4`} placeholder="Açıklama" value={it.description}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, description: e.target.value } : x)))}
          />
          <input
            className={`${inputClass} col-span-2`} type="number" step="0.01" placeholder="Miktar" value={it.quantity}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, quantity: e.target.value } : x)))}
          />
          <input
            className={`${inputClass} col-span-2`} placeholder="Birim" value={it.unit}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, unit: e.target.value } : x)))}
          />
          <input
            className={`${inputClass} col-span-3`} type="number" step="0.01" placeholder="Tahmini Birim Fiyat"
            value={it.estimated_unit_cost}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, estimated_unit_cost: e.target.value } : x)))}
          />
          <button
            type="button" className="col-span-1 text-xs text-danger disabled:opacity-40" disabled={items.length <= 1}
            onClick={() => setItems(items.filter((_, j) => j !== i))}
          >
            Sil
          </button>
          <select
            className={`${inputClass} col-span-4`} value={it.cost_code_id}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, cost_code_id: e.target.value } : x)))}
          >
            <option value="">Maliyet Kodu (opsiyonel)</option>
            {costCodes.map((c) => (
              <option key={c.id} value={c.id}>{costCodeLabel(c)}</option>
            ))}
          </select>
          <select
            className={`${inputClass} col-span-4`} value={it.wbs_node_id}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, wbs_node_id: e.target.value } : x)))}
          >
            <option value="">WBS (opsiyonel)</option>
            {wbsNodes.map((n) => (
              <option key={n.id} value={n.id}>{n.code} — {n.name}</option>
            ))}
          </select>
          <select
            className={`${inputClass} col-span-4`} value={it.budget_line_id}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, budget_line_id: e.target.value } : x)))}
          >
            <option value="">Bütçe Kalemi (opsiyonel)</option>
            {budgetLines.map((l) => (
              <option key={l.id} value={l.id}>{l.description}</option>
            ))}
          </select>
        </div>
      ))}
      <Button type="button" variant="ghost" onClick={() => setItems([...items, emptyPRItem()])}>
        + Kalem Ekle
      </Button>
    </div>
  );
}

function prItemsToPayload(items: PRItemDraft[]) {
  return items
    .filter((it) => it.description.trim() !== "")
    .map((it) => ({
      wbs_node_id: it.wbs_node_id, cost_code_id: it.cost_code_id, budget_line_id: it.budget_line_id,
      description: it.description, quantity: Number(it.quantity) || 0, unit: it.unit,
      estimated_unit_cost: it.estimated_unit_cost ? Number(it.estimated_unit_cost) : null,
      estimated_total: Number(it.estimated_total) || 0,
    }));
}

// ---------- Purchase Request kartı ----------

function PurchaseRequestCard({ project, pr, locked }: { project: Project; pr: PurchaseRequest; locked: boolean }) {
  const { busy, error, run } = usePurchasingAction(locked);
  const toast = useToast();
  const { askReason, dialog } = useReasonDialog();
  const [expanded, setExpanded] = useState(false);
  const [detailItems, setDetailItems] = useState<PurchaseRequestItem[] | null>(null);

  useEffect(() => {
    if (!expanded || detailItems) return;
    (async () => {
      try {
        const full = await apiClient<{ items: PurchaseRequestItem[] }>(`/api/v1/projects/${project.id}/purchase-requests/${pr.id}`);
        setDetailItems(full.items);
      } catch {
        setDetailItems([]);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded]);

  const isDraft = pr.status === "draft";
  const isSubmitted = pr.status === "submitted";

  async function submit() {
    const ok = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-requests/${pr.id}/submit`, { method: "POST" }));
    if (ok) toast.success(`${pr.pr_no} gönderildi.`);
  }
  async function withdraw() {
    const ok = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-requests/${pr.id}/withdraw`, { method: "POST" }));
    if (ok) toast.success("Talep taslağa geri çekildi.");
  }
  async function approve() {
    const ok = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-requests/${pr.id}/approve`, { method: "POST" }));
    if (ok) toast.success(`${pr.pr_no} onaylandı.`);
  }
  async function reject() {
    const reason = await askReason({
      title: "Talebi Reddet", message: `${pr.pr_no} reddedilecek.`, label: "Red nedeni",
      confirmLabel: "Reddet", danger: true, required: true,
    });
    if (reason === null) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-requests/${pr.id}/reject`, { method: "POST", body: JSON.stringify({ reason }) }));
    if (done) toast.success("Talep reddedildi.");
  }
  async function cancel() {
    const reason = await askReason({
      title: "Talebi İptal Et", message: `${pr.pr_no} iptal edilecek.`, label: "İptal nedeni",
      confirmLabel: "İptal Et", danger: true, required: true,
    });
    if (reason === null) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-requests/${pr.id}/cancel`, { method: "POST", body: JSON.stringify({ reason }) }));
    if (done) toast.success("Talep iptal edildi.");
  }

  return (
    <div className="rounded-md border border-border p-3">
      <button type="button" className="flex w-full items-center justify-between gap-2 text-left" onClick={() => setExpanded(!expanded)}>
        <div>
          <span className="font-medium">{pr.pr_no}</span>
          <span className="ml-2 text-text-muted">{pr.title}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-text-muted">{formatMoney(pr.estimated_total, project.currency)}</span>
          <StatusBadge status={pr.status} registry={PURCHASE_REQUEST_STATUS} />
        </div>
      </button>
      {expanded && (
        <div className="mt-3 flex flex-col gap-3 border-t border-border pt-3 text-sm">
          {pr.description && <p className="text-text-muted">{pr.description}</p>}
          {pr.needed_by && <Field label="İhtiyaç Tarihi" value={formatDate(pr.needed_by)} />}
          {pr.rejection_reason && <p className="text-xs text-danger">Red gerekçesi: {pr.rejection_reason}</p>}
          {pr.cancel_reason && <p className="text-xs text-danger">İptal gerekçesi: {pr.cancel_reason}</p>}
          <Table>
            <thead>
              <tr><Th>Kalem</Th><Th className="text-right">Miktar</Th><Th className="text-right">Tahmini Tutar</Th></tr>
            </thead>
            <tbody>
              {(detailItems ?? []).map((it) => (
                <Tr key={it.id}>
                  <Td>{it.description}</Td>
                  <Td className="text-right">{it.quantity} {it.unit}</Td>
                  <Td className="text-right">{formatMoney(it.estimated_total, project.currency)}</Td>
                </Tr>
              ))}
            </tbody>
          </Table>
          {!locked && (
            <div className="flex flex-wrap gap-2">
              {isDraft && (
                <>
                  <Button type="button" disabled={busy} onClick={submit}>Gönder</Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>İptal</Button>
                </>
              )}
              {isSubmitted && (
                <>
                  <Button type="button" variant="secondary" disabled={busy} onClick={withdraw}>Geri Çek</Button>
                  <Button type="button" disabled={busy} onClick={approve}>Onayla</Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={reject}>Reddet</Button>
                </>
              )}
              {pr.status === "approved" && (
                <Button type="button" variant="danger" disabled={busy} onClick={cancel}>İptal</Button>
              )}
            </div>
          )}
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
      )}
      {dialog}
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs uppercase tracking-widest text-text-muted">{label}</span>
      <span>{value}</span>
    </div>
  );
}

function PurchaseRequestsTab({
  project, purchaseRequests, costCodes, wbsNodes, budgetLines, locked,
}: {
  project: Project; purchaseRequests: PurchaseRequest[]; costCodes: OrganizationCostCode[]; wbsNodes: WBSNode[];
  budgetLines: BudgetLine[]; locked: boolean;
}) {
  const { busy, error, run } = usePurchasingAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ title: "", description: "", needed_by: "" });
  const [items, setItems] = useState<PRItemDraft[]>([emptyPRItem()]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/purchase-requests`, {
        method: "POST",
        body: JSON.stringify({ title: form.title, description: form.description, needed_by: form.needed_by || null, items: prItemsToPayload(items) }),
      })
    );
    if (ok) {
      setForm({ title: "", description: "", needed_by: "" });
      setItems([emptyPRItem()]);
      setOpen(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {purchaseRequests.length === 0 ? (
        <p className="text-text-muted">Henüz satın alma talebi yok.</p>
      ) : (
        <div className="flex flex-col gap-2">
          {purchaseRequests.map((pr) => (
            <PurchaseRequestCard key={pr.id} project={project} pr={pr} locked={locked} />
          ))}
        </div>
      )}
      {open ? (
        <form onSubmit={submit} className="flex flex-col gap-2 rounded-md border border-border p-3">
          <input className={inputClass} placeholder="Başlık" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} />
          <Textarea placeholder="Açıklama" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
          <input className={inputClass} type="date" value={form.needed_by} onChange={(e) => setForm({ ...form, needed_by: e.target.value })} />
          <PRItemsEditor items={items} setItems={setItems} costCodes={costCodes} wbsNodes={wbsNodes} budgetLines={budgetLines} />
          <div className="flex gap-2">
            <Button type="submit" disabled={busy || !form.title}>Oluştur</Button>
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>Vazgeç</Button>
          </div>
          {error && <p className="text-xs text-danger">{error}</p>}
        </form>
      ) : (
        <Button type="button" variant="secondary" onClick={() => setOpen(true)} disabled={locked}>+ Talep Oluştur</Button>
      )}
    </div>
  );
}

// ---------- RFQ ----------

type RFQItemDraft = { wbs_node_id: string; cost_code_id: string; budget_line_id: string; description: string; quantity: string; unit: string };
const emptyRFQItem = (): RFQItemDraft => ({ wbs_node_id: "", cost_code_id: "", budget_line_id: "", description: "", quantity: "1", unit: "adet" });

function RFQCard({
  project, rfq, onCompare, locked,
}: {
  project: Project; rfq: RFQ; onCompare: (rfqId: string) => void; locked: boolean;
}) {
  const { busy, error, run } = usePurchasingAction(locked);
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<{ items: RFQItem[]; suppliers: RFQSupplier[] } | null>(null);

  useEffect(() => {
    if (!expanded || detail) return;
    (async () => {
      try {
        const full = await apiClient<{ items: RFQItem[]; suppliers: RFQSupplier[] }>(`/api/v1/projects/${project.id}/rfqs/${rfq.id}`);
        setDetail(full);
      } catch {
        setDetail({ items: [], suppliers: [] });
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded]);

  async function issue() {
    const ok = await run(() => apiClient(`/api/v1/projects/${project.id}/rfqs/${rfq.id}/issue`, { method: "POST" }));
    if (ok) toast.success(`${rfq.rfq_no} tedarikçilere gönderildi.`);
  }
  async function close() {
    const ok2 = await confirm({ title: "RFQ'yu Kapat", message: "Kazanan seçilmeden kapatılacak.", confirmLabel: "Kapat" });
    if (!ok2) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/rfqs/${rfq.id}/close`, { method: "POST" }));
    if (done) toast.success("RFQ kapatıldı.");
  }
  async function cancel() {
    const ok2 = await confirm({ title: "RFQ'yu İptal Et", message: "Bu RFQ iptal edilecek.", confirmLabel: "İptal Et", danger: true });
    if (!ok2) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/rfqs/${rfq.id}/cancel`, { method: "POST" }));
    if (done) toast.success("RFQ iptal edildi.");
  }

  return (
    <div className="rounded-md border border-border p-3">
      <button type="button" className="flex w-full items-center justify-between gap-2 text-left" onClick={() => setExpanded(!expanded)}>
        <div>
          <span className="font-medium">{rfq.rfq_no}</span>
          <span className="ml-2 text-text-muted">{rfq.title}</span>
        </div>
        <StatusBadge status={rfq.status} registry={RFQ_STATUS} />
      </button>
      {expanded && (
        <div className="mt-3 flex flex-col gap-3 border-t border-border pt-3 text-sm">
          <Field label="Tarih" value={`${formatDate(rfq.issue_date)} → ${formatDate(rfq.due_date)}`} />
          {rfq.notes && <p className="text-text-muted">{rfq.notes}</p>}
          <div>
            <span className="text-xs uppercase tracking-widest text-text-muted">Kalemler</span>
            <Table>
              <thead><tr><Th>Açıklama</Th><Th className="text-right">Miktar</Th></tr></thead>
              <tbody>
                {(detail?.items ?? []).map((it) => (
                  <Tr key={it.id}><Td>{it.description}</Td><Td className="text-right">{it.quantity} {it.unit}</Td></Tr>
                ))}
              </tbody>
            </Table>
          </div>
          <div>
            <span className="text-xs uppercase tracking-widest text-text-muted">Davetli Tedarikçiler</span>
            <div className="mt-1 flex flex-wrap gap-2">
              {(detail?.suppliers ?? []).map((s) => (
                <span key={s.id} className="rounded-md border border-border px-2 py-1 text-xs">
                  {s.supplier_code} — {s.supplier_name}
                  {s.response_status === "responded" && <span className="ml-1 text-success">✓ teklif verdi</span>}
                </span>
              ))}
            </div>
          </div>
          {!locked && (
            <div className="flex flex-wrap gap-2">
              {rfq.status === "draft" && (
                <>
                  <Button type="button" disabled={busy} onClick={issue}>Gönder</Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>İptal</Button>
                </>
              )}
              {rfq.status === "issued" && (
                <>
                  <Button type="button" variant="secondary" onClick={() => onCompare(rfq.id)}>Teklifleri Karşılaştır</Button>
                  <Button type="button" variant="secondary" disabled={busy} onClick={close}>Kapat</Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>İptal</Button>
                </>
              )}
              {rfq.status === "closed" && rfq.awarded_quotation_id && (
                <Button type="button" variant="secondary" onClick={() => onCompare(rfq.id)}>Ödül Detayını Gör</Button>
              )}
            </div>
          )}
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
      )}
      {dialog}
    </div>
  );
}

function RFQsTab({
  project, rfqs, purchaseRequests, suppliers, costCodes, wbsNodes, budgetLines, onCompare, locked,
}: {
  project: Project; rfqs: RFQ[]; purchaseRequests: PurchaseRequest[]; suppliers: Supplier[];
  costCodes: OrganizationCostCode[]; wbsNodes: WBSNode[]; budgetLines: BudgetLine[];
  onCompare: (rfqId: string) => void; locked: boolean;
}) {
  const { busy, error, run } = usePurchasingAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ title: "", purchase_request_id: "", issue_date: istanbulDate(new Date()), due_date: "", notes: "" });
  const [supplierIds, setSupplierIds] = useState<string[]>([]);
  const [items, setItems] = useState<RFQItemDraft[]>([emptyRFQItem()]);

  const approvedPRs = purchaseRequests.filter((pr) => pr.status === "approved");
  const activeSuppliers = suppliers.filter((s) => s.is_active);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/rfqs`, {
        method: "POST",
        body: JSON.stringify({
          title: form.title, purchase_request_id: form.purchase_request_id, issue_date: form.issue_date,
          due_date: form.due_date || null, notes: form.notes, supplier_ids: supplierIds,
          items: form.purchase_request_id
            ? []
            : items.filter((it) => it.description.trim()).map((it) => ({
                wbs_node_id: it.wbs_node_id, cost_code_id: it.cost_code_id, budget_line_id: it.budget_line_id,
                description: it.description, quantity: Number(it.quantity) || 0, unit: it.unit,
              })),
        }),
      })
    );
    if (ok) {
      setForm({ title: "", purchase_request_id: "", issue_date: istanbulDate(new Date()), due_date: "", notes: "" });
      setSupplierIds([]);
      setItems([emptyRFQItem()]);
      setOpen(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {rfqs.length === 0 ? (
        <p className="text-text-muted">Henüz RFQ yok.</p>
      ) : (
        <div className="flex flex-col gap-2">
          {rfqs.map((rfq) => (
            <RFQCard key={rfq.id} project={project} rfq={rfq} onCompare={onCompare} locked={locked} />
          ))}
        </div>
      )}
      {open ? (
        <form onSubmit={submit} className="flex flex-col gap-2 rounded-md border border-border p-3">
          <input className={inputClass} placeholder="Başlık" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} />
          <Select value={form.purchase_request_id} onChange={(e) => setForm({ ...form, purchase_request_id: e.target.value })}>
            <option value="">Onaylı talepten kalem al (opsiyonel)</option>
            {approvedPRs.map((pr) => (
              <option key={pr.id} value={pr.id}>{pr.pr_no} — {pr.title}</option>
            ))}
          </Select>
          <div className="grid grid-cols-2 gap-2">
            <input className={inputClass} type="date" value={form.issue_date} onChange={(e) => setForm({ ...form, issue_date: e.target.value })} />
            <input className={inputClass} type="date" placeholder="Son yanıt tarihi" value={form.due_date} onChange={(e) => setForm({ ...form, due_date: e.target.value })} />
          </div>
          <div>
            <span className="text-xs uppercase tracking-widest text-text-muted">Davet Edilecek Tedarikçiler</span>
            <div className="mt-1 flex flex-wrap gap-2">
              {activeSuppliers.map((s) => (
                <label key={s.id} className="flex items-center gap-1 rounded-md border border-border px-2 py-1 text-xs">
                  <input
                    type="checkbox" checked={supplierIds.includes(s.id)}
                    onChange={(e) => setSupplierIds(e.target.checked ? [...supplierIds, s.id] : supplierIds.filter((id) => id !== s.id))}
                  />
                  {s.code} — {s.legal_name}
                </label>
              ))}
            </div>
          </div>
          {!form.purchase_request_id && (
            <RFQItemsEditor items={items} setItems={setItems} costCodes={costCodes} wbsNodes={wbsNodes} budgetLines={budgetLines} />
          )}
          <Textarea placeholder="Not" value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          <div className="flex gap-2">
            <Button type="submit" disabled={busy || !form.title}>Oluştur</Button>
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>Vazgeç</Button>
          </div>
          {error && <p className="text-xs text-danger">{error}</p>}
        </form>
      ) : (
        <Button type="button" variant="secondary" onClick={() => setOpen(true)} disabled={locked}>+ RFQ Oluştur</Button>
      )}
    </div>
  );
}

function RFQItemsEditor({
  items, setItems, costCodes, wbsNodes, budgetLines,
}: {
  items: RFQItemDraft[]; setItems: (v: RFQItemDraft[]) => void;
  costCodes: OrganizationCostCode[]; wbsNodes: WBSNode[]; budgetLines: BudgetLine[];
}) {
  return (
    <div className="flex flex-col gap-2">
      {items.map((it, i) => (
        <div key={i} className="grid grid-cols-12 gap-2 rounded-md border border-border p-2">
          <input className={`${inputClass} col-span-6`} placeholder="Açıklama" value={it.description} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, description: e.target.value } : x)))} />
          <input className={`${inputClass} col-span-2`} type="number" step="0.01" placeholder="Miktar" value={it.quantity} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, quantity: e.target.value } : x)))} />
          <input className={`${inputClass} col-span-3`} placeholder="Birim" value={it.unit} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, unit: e.target.value } : x)))} />
          <button type="button" className="col-span-1 text-xs text-danger disabled:opacity-40" disabled={items.length <= 1} onClick={() => setItems(items.filter((_, j) => j !== i))}>Sil</button>
          <select className={`${inputClass} col-span-4`} value={it.cost_code_id} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, cost_code_id: e.target.value } : x)))}>
            <option value="">Maliyet Kodu (opsiyonel)</option>
            {costCodes.map((c) => <option key={c.id} value={c.id}>{costCodeLabel(c)}</option>)}
          </select>
          <select className={`${inputClass} col-span-4`} value={it.wbs_node_id} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, wbs_node_id: e.target.value } : x)))}>
            <option value="">WBS (opsiyonel)</option>
            {wbsNodes.map((n) => <option key={n.id} value={n.id}>{n.code} — {n.name}</option>)}
          </select>
          <select className={`${inputClass} col-span-4`} value={it.budget_line_id} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, budget_line_id: e.target.value } : x)))}>
            <option value="">Bütçe Kalemi (opsiyonel)</option>
            {budgetLines.map((l) => <option key={l.id} value={l.id}>{l.description}</option>)}
          </select>
        </div>
      ))}
      <Button type="button" variant="ghost" onClick={() => setItems([...items, emptyRFQItem()])}>+ Kalem Ekle</Button>
    </div>
  );
}

// ---------- Teklif Karşılaştırma ----------

function ComparisonTab({
  project, rfqs, selectedRFQId, setSelectedRFQId, locked,
}: {
  project: Project; rfqs: RFQ[]; selectedRFQId: string | null; setSelectedRFQId: (id: string | null) => void; locked: boolean;
}) {
  const router = useRouter();
  const toast = useToast();
  const { askReason, dialog } = useReasonDialog();
  const [comparison, setComparison] = useState<{ rows: BidComparisonRow[]; quotations: SupplierQuotation[] } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [rfqSuppliers, setRfqSuppliers] = useState<RFQSupplier[]>([]);
  const [quoteForm, setQuoteForm] = useState({ supplier_id: "", quotation_date: istanbulDate(new Date()), tax_rate: "20" });
  const [quoteItems, setQuoteItems] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);

  const comparableRFQs = rfqs.filter((r) => r.status === "issued" || r.status === "closed");
  const rfq = rfqs.find((r) => r.id === selectedRFQId) ?? null;

  useEffect(() => {
    // selectedRFQId boşsa hiçbir şey ÇEKME -- render zaten `rfq` (aşağıda,
    // rfqs.find sonucu) null olduğunda karşılaştırma bloğunu gizler, bu
    // yüzden burada AYRICA comparison'ı sıfırlamaya gerek yok (effect
    // gövdesinde senkron setState'ten kaçınmak için, bkz. lint kuralı).
    if (!selectedRFQId) return;
    (async () => {
      setLoading(true);
      try {
        const [cmp, detail] = await Promise.all([
          apiClient<{ rows: BidComparisonRow[]; quotations: SupplierQuotation[] }>(`/api/v1/projects/${project.id}/rfqs/${selectedRFQId}/comparison`),
          apiClient<{ suppliers: RFQSupplier[] }>(`/api/v1/projects/${project.id}/rfqs/${selectedRFQId}`),
        ]);
        setComparison(cmp);
        setRfqSuppliers(detail.suppliers);
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      } finally {
        setLoading(false);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedRFQId]);

  async function submitQuote(e: FormEvent) {
    e.preventDefault();
    if (!rfq || !comparison) return;
    setBusy(true);
    setError(null);
    try {
      await apiClient(`/api/v1/projects/${project.id}/rfqs/${rfq.id}/quotations`, {
        method: "POST",
        body: JSON.stringify({
          supplier_id: quoteForm.supplier_id, quotation_date: quoteForm.quotation_date, tax_rate: Number(quoteForm.tax_rate) || 0,
          items: comparison.rows.map((row) => ({
            rfq_item_id: row.item.id, quantity: row.item.quantity, unit_price: Number(quoteItems[row.item.id]) || 0,
          })).filter((it) => it.unit_price > 0),
        }),
      });
      setQuoteForm({ ...quoteForm, supplier_id: "" });
      setQuoteItems({});
      router.refresh();
      // Yerel karşılaştırma verisini de tazele (router.refresh() yalnızca
      // page.tsx'in server-fetch'lerini yeniler, bu istemci-taraflı veriyi
      // DEĞİL).
      const cmp = await apiClient<{ rows: BidComparisonRow[]; quotations: SupplierQuotation[] }>(`/api/v1/projects/${project.id}/rfqs/${rfq.id}/comparison`);
      setComparison(cmp);
      toast.success("Teklif kaydedildi.");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  async function award(quotationId: string) {
    if (!rfq) return;
    const winner = comparison?.quotations.find((q) => q.id === quotationId);
    const notes = await askReason({
      title: "Kazananı Seç",
      message: `${rfq.rfq_no} için kazanan ${winner ? `${winner.supplier_code} (${formatMoney(winner.total, project.currency)})` : "seçilen teklif"} olarak işaretlenecek ve RFQ kapanacak.`,
      label: "Ödül notu",
      confirmLabel: "Kazanan Olarak Seç",
    });
    if (notes === null) return;
    setBusy(true);
    setError(null);
    try {
      await apiClient(`/api/v1/projects/${project.id}/rfqs/${rfq.id}/award`, { method: "POST", body: JSON.stringify({ quotation_id: quotationId, notes }) });
      router.refresh();
      toast.success("Ödül verildi.");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  const respondedSuppliers = rfqSuppliers.filter((s) => comparison?.quotations.some((q) => q.supplier_id === s.supplier_id));
  const notYetQuoted = rfqSuppliers.filter((s) => !comparison?.quotations.some((q) => q.supplier_id === s.supplier_id));

  return (
    <div className="flex flex-col gap-3">
      {dialog}
      <Select value={selectedRFQId ?? ""} onChange={(e) => setSelectedRFQId(e.target.value || null)}>
        <option value="">Karşılaştırılacak RFQ seçin…</option>
        {comparableRFQs.map((r) => (
          <option key={r.id} value={r.id}>{r.rfq_no} — {r.title}</option>
        ))}
      </Select>

      {loading && <p className="text-text-muted">Yükleniyor…</p>}
      {error && <p className="text-xs text-danger">{error}</p>}

      {comparison && rfq && (
        <>
          <div className="overflow-x-auto">
            <Table>
              <thead>
                <tr>
                  <Th>Kalem</Th>
                  {comparison.quotations.map((q) => (
                    <Th key={q.id} className="text-right">
                      {q.supplier_code}
                      {rfq.awarded_quotation_id === q.id && <span className="ml-1 text-success">★</span>}
                    </Th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {comparison.rows.map((row) => (
                  <Tr key={row.item.id}>
                    <Td>{row.item.description} <span className="text-text-muted">({row.item.quantity} {row.item.unit})</span></Td>
                    {comparison.quotations.map((q) => {
                      const cell = row.cells[q.supplier_id];
                      return (
                        <Td key={q.id} className="text-right">
                          {cell ? formatMoney(cell.line_total, project.currency) : "—"}
                        </Td>
                      );
                    })}
                  </Tr>
                ))}
                <Tr>
                  <Td className="font-medium">Toplam (KDV dahil)</Td>
                  {comparison.quotations.map((q) => (
                    <Td key={q.id} className="text-right font-medium">{formatMoney(q.total, project.currency)}</Td>
                  ))}
                </Tr>
              </tbody>
            </Table>
          </div>

          {rfq.status === "issued" && comparison.quotations.length > 0 && !locked && (
            <div className="flex flex-wrap gap-2">
              {comparison.quotations.map((q) => (
                <Button key={q.id} type="button" variant="secondary" disabled={busy} onClick={() => award(q.id)}>
                  {q.supplier_code} Kazandı
                </Button>
              ))}
            </div>
          )}

          {respondedSuppliers.length > 0 && (
            <p className="text-xs text-text-muted">Teklif veren: {respondedSuppliers.map((s) => s.supplier_code).join(", ")}</p>
          )}

          {rfq.status === "issued" && notYetQuoted.length > 0 && !locked && (
            <form onSubmit={submitQuote} className="flex flex-col gap-2 rounded-md border border-border p-3">
              <span className="text-xs uppercase tracking-widest text-text-muted">Yeni Teklif Gir</span>
              <div className="grid grid-cols-3 gap-2">
                <Select value={quoteForm.supplier_id} onChange={(e) => setQuoteForm({ ...quoteForm, supplier_id: e.target.value })}>
                  <option value="">Tedarikçi seçin…</option>
                  {notYetQuoted.map((s) => (
                    <option key={s.supplier_id} value={s.supplier_id}>{s.supplier_code} — {s.supplier_name}</option>
                  ))}
                </Select>
                <input className={inputClass} type="date" value={quoteForm.quotation_date} onChange={(e) => setQuoteForm({ ...quoteForm, quotation_date: e.target.value })} />
                <input className={inputClass} type="number" step="0.01" placeholder="KDV %" value={quoteForm.tax_rate} onChange={(e) => setQuoteForm({ ...quoteForm, tax_rate: e.target.value })} />
              </div>
              <div className="flex flex-col gap-1">
                {comparison.rows.map((row) => (
                  <div key={row.item.id} className="grid grid-cols-3 items-center gap-2 text-xs">
                    <span className="col-span-2">{row.item.description} ({row.item.quantity} {row.item.unit})</span>
                    <input
                      className={inputClass} type="number" step="0.01" placeholder="Birim fiyat"
                      value={quoteItems[row.item.id] ?? ""}
                      onChange={(e) => setQuoteItems({ ...quoteItems, [row.item.id]: e.target.value })}
                    />
                  </div>
                ))}
              </div>
              <div>
                <Button type="submit" disabled={busy || !quoteForm.supplier_id}>Teklifi Kaydet</Button>
              </div>
            </form>
          )}
        </>
      )}
    </div>
  );
}

// ---------- Purchase Order ----------

type POItemDraft = { wbs_node_id: string; cost_code_id: string; budget_line_id: string; description: string; quantity: string; unit: string; unit_price: string };
const emptyPOItem = (): POItemDraft => ({ wbs_node_id: "", cost_code_id: "", budget_line_id: "", description: "", quantity: "1", unit: "adet", unit_price: "" });

function POCard({ project, po, locked }: { project: Project; po: PurchaseOrder; locked: boolean }) {
  const { busy, error, run } = usePurchasingAction(locked);
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const { askReason, dialog: reasonDialog } = useReasonDialog();
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<{ items: PurchaseOrderItem[]; commitments: Commitment[] } | null>(null);

  useEffect(() => {
    if (!expanded || detail) return;
    (async () => {
      try {
        const full = await apiClient<{ items: PurchaseOrderItem[]; commitments: Commitment[] }>(`/api/v1/projects/${project.id}/purchase-orders/${po.id}`);
        setDetail(full);
      } catch {
        setDetail({ items: [], commitments: [] });
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded]);

  async function approve() {
    const ok2 = await confirm({ title: "Siparişi Onayla", message: "Onay, ticari tabanı kilitler ve Maliyet Kontrolü'nde bir taahhüt (commitment) oluşturur.", confirmLabel: "Onayla" });
    if (!ok2) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-orders/${po.id}/approve`, { method: "POST" }));
    if (done) toast.success(`${po.po_no} onaylandı.`);
  }
  async function cancel() {
    const reason = await askReason({
      title: "Siparişi İptal Et",
      message: po.status === "approved" ? "Bu sipariş iptal edilecek — bağlı taahhüt(ler) serbest bırakılacak." : "Bu sipariş iptal edilecek.",
      label: "İptal nedeni", confirmLabel: "İptal Et", danger: true, required: true,
    });
    if (reason === null) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-orders/${po.id}/cancel`, { method: "POST", body: JSON.stringify({ reason }) }));
    if (done) toast.success("Sipariş iptal edildi.");
  }
  async function close() {
    const ok2 = await confirm({ title: "Siparişi Kapat", message: "Bu, arşivleme amaçlı bir işarettir — taahhüt etkilenmez.", confirmLabel: "Kapat" });
    if (!ok2) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/purchase-orders/${po.id}/close`, { method: "POST" }));
    if (done) toast.success("Sipariş kapatıldı.");
  }

  return (
    <div className="rounded-md border border-border p-3">
      <button type="button" className="flex w-full items-center justify-between gap-2 text-left" onClick={() => setExpanded(!expanded)}>
        <div>
          <span className="font-medium">{po.po_no}</span>
          <span className="ml-2 text-text-muted">{po.supplier_name ?? po.supplier_id}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-text-muted">{formatMoney(po.total, project.currency)}</span>
          <StatusBadge status={po.status} registry={PURCHASE_ORDER_STATUS} />
        </div>
      </button>
      {expanded && (
        <div className="mt-3 flex flex-col gap-3 border-t border-border pt-3 text-sm">
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <Field label="Sipariş Tarihi" value={formatDate(po.issue_date)} />
            <Field label="Teslim Tarihi" value={formatDate(po.expected_delivery_date)} />
            <Field label="Ara Toplam" value={formatMoney(po.subtotal, project.currency)} />
            <Field label="KDV" value={`%${po.tax_rate} · ${formatMoney(po.tax, project.currency)}`} />
          </div>
          {po.cancel_reason && <p className="text-xs text-danger">İptal gerekçesi: {po.cancel_reason}</p>}
          <Table>
            <thead><tr><Th>Kalem</Th><Th className="text-right">Miktar</Th><Th className="text-right">Birim Fiyat</Th><Th className="text-right">Tutar</Th></tr></thead>
            <tbody>
              {(detail?.items ?? []).map((it) => (
                <Tr key={it.id}>
                  <Td>{it.description}</Td>
                  <Td className="text-right">{it.quantity} {it.unit}</Td>
                  <Td className="text-right">{formatMoney(it.unit_price, project.currency)}</Td>
                  <Td className="text-right">{formatMoney(it.line_total, project.currency)}</Td>
                </Tr>
              ))}
            </tbody>
          </Table>
          {detail && detail.commitments.length > 0 && (
            <div>
              <span className="text-xs uppercase tracking-widest text-text-muted">Bağlı Maliyet Taahhütleri</span>
              <ul className="mt-1 flex flex-col gap-1 text-xs text-text-muted">
                {detail.commitments.map((c) => (
                  <li key={c.id}>
                    {formatMoney(c.committed_amount, project.currency)} — {c.status === "active" ? "aktif" : "iptal edildi"}
                  </li>
                ))}
              </ul>
            </div>
          )}
          {!locked && (
            <div className="flex flex-wrap gap-2">
              {po.status === "draft" && (
                <>
                  <Button type="button" disabled={busy} onClick={approve}>Onayla</Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>İptal</Button>
                </>
              )}
              {po.status === "approved" && (
                <>
                  <Button type="button" variant="secondary" disabled={busy} onClick={close}>Kapat</Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>İptal</Button>
                </>
              )}
            </div>
          )}
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
      )}
      {dialog}
      {reasonDialog}
    </div>
  );
}

function PurchaseOrdersTab({
  project, purchaseOrders, suppliers, costCodes, wbsNodes, budgetLines, locked,
}: {
  project: Project; purchaseOrders: PurchaseOrder[]; suppliers: Supplier[]; costCodes: OrganizationCostCode[];
  wbsNodes: WBSNode[]; budgetLines: BudgetLine[]; locked: boolean;
}) {
  const { busy, error, run } = usePurchasingAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ supplier_id: "", issue_date: istanbulDate(new Date()), expected_delivery_date: "", payment_terms: "", delivery_address: "", notes: "", tax_rate: "20" });
  const [items, setItems] = useState<POItemDraft[]>([emptyPOItem()]);
  const activeSuppliers = suppliers.filter((s) => s.is_active);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/purchase-orders`, {
        method: "POST",
        body: JSON.stringify({
          supplier_id: form.supplier_id, issue_date: form.issue_date, expected_delivery_date: form.expected_delivery_date || null,
          payment_terms: form.payment_terms, delivery_address: form.delivery_address, notes: form.notes, tax_rate: Number(form.tax_rate) || 0,
          items: items.filter((it) => it.description.trim() && it.cost_code_id).map((it) => ({
            wbs_node_id: it.wbs_node_id, cost_code_id: it.cost_code_id, budget_line_id: it.budget_line_id,
            description: it.description, quantity: Number(it.quantity) || 0, unit: it.unit, unit_price: Number(it.unit_price) || 0,
          })),
        }),
      })
    );
    if (ok) {
      setForm({ supplier_id: "", issue_date: istanbulDate(new Date()), expected_delivery_date: "", payment_terms: "", delivery_address: "", notes: "", tax_rate: "20" });
      setItems([emptyPOItem()]);
      setOpen(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {purchaseOrders.length === 0 ? (
        <p className="text-text-muted">Henüz sipariş yok.</p>
      ) : (
        <div className="flex flex-col gap-2">
          {purchaseOrders.map((po) => (
            <POCard key={po.id} project={project} po={po} locked={locked} />
          ))}
        </div>
      )}
      {open ? (
        <form onSubmit={submit} className="flex flex-col gap-2 rounded-md border border-border p-3">
          <Select value={form.supplier_id} onChange={(e) => setForm({ ...form, supplier_id: e.target.value })}>
            <option value="">Tedarikçi seçin…</option>
            {activeSuppliers.map((s) => <option key={s.id} value={s.id}>{s.code} — {s.legal_name}</option>)}
          </Select>
          <div className="grid grid-cols-3 gap-2">
            <input className={inputClass} type="date" value={form.issue_date} onChange={(e) => setForm({ ...form, issue_date: e.target.value })} />
            <input className={inputClass} type="date" placeholder="Teslim tarihi" value={form.expected_delivery_date} onChange={(e) => setForm({ ...form, expected_delivery_date: e.target.value })} />
            <input className={inputClass} type="number" step="0.01" placeholder="KDV %" value={form.tax_rate} onChange={(e) => setForm({ ...form, tax_rate: e.target.value })} />
          </div>
          <input className={inputClass} placeholder="Ödeme koşulları" value={form.payment_terms} onChange={(e) => setForm({ ...form, payment_terms: e.target.value })} />
          <Textarea placeholder="Teslimat adresi" value={form.delivery_address} onChange={(e) => setForm({ ...form, delivery_address: e.target.value })} />
          <div className="flex flex-col gap-2">
            {items.map((it, i) => (
              <div key={i} className="grid grid-cols-12 gap-2 rounded-md border border-border p-2">
                <input className={`${inputClass} col-span-4`} placeholder="Açıklama" value={it.description} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, description: e.target.value } : x)))} />
                <input className={`${inputClass} col-span-2`} type="number" step="0.01" placeholder="Miktar" value={it.quantity} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, quantity: e.target.value } : x)))} />
                <input className={`${inputClass} col-span-2`} placeholder="Birim" value={it.unit} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, unit: e.target.value } : x)))} />
                <input className={`${inputClass} col-span-3`} type="number" step="0.01" placeholder="Birim Fiyat" value={it.unit_price} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, unit_price: e.target.value } : x)))} />
                <button type="button" className="col-span-1 text-xs text-danger disabled:opacity-40" disabled={items.length <= 1} onClick={() => setItems(items.filter((_, j) => j !== i))}>Sil</button>
                <select className={`${inputClass} col-span-6`} value={it.cost_code_id} required onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, cost_code_id: e.target.value } : x)))}>
                  <option value="">Maliyet Kodu (zorunlu)</option>
                  {costCodes.map((c) => <option key={c.id} value={c.id}>{costCodeLabel(c)}</option>)}
                </select>
                <select className={`${inputClass} col-span-3`} value={it.wbs_node_id} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, wbs_node_id: e.target.value } : x)))}>
                  <option value="">WBS</option>
                  {wbsNodes.map((n) => <option key={n.id} value={n.id}>{n.code}</option>)}
                </select>
                <select className={`${inputClass} col-span-3`} value={it.budget_line_id} onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, budget_line_id: e.target.value } : x)))}>
                  <option value="">Bütçe Kalemi</option>
                  {budgetLines.map((l) => <option key={l.id} value={l.id}>{l.description}</option>)}
                </select>
              </div>
            ))}
            <Button type="button" variant="ghost" onClick={() => setItems([...items, emptyPOItem()])}>+ Kalem Ekle</Button>
          </div>
          <div className="flex gap-2">
            <Button type="submit" disabled={busy || !form.supplier_id}>Oluştur</Button>
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>Vazgeç</Button>
          </div>
          {error && <p className="text-xs text-danger">{error}</p>}
        </form>
      ) : (
        <Button type="button" variant="secondary" onClick={() => setOpen(true)} disabled={locked}>+ Sipariş Oluştur</Button>
      )}
    </div>
  );
}

// ---------- Üst seviye çalışma alanı ----------

export function PurchasingWorkspace({
  project, purchaseRequests, rfqs, purchaseOrders, suppliers, costCodes, wbsNodes, budgetLines, locked,
}: {
  project: Project; purchaseRequests: PurchaseRequest[]; rfqs: RFQ[]; purchaseOrders: PurchaseOrder[];
  suppliers: Supplier[]; costCodes: OrganizationCostCode[]; wbsNodes: WBSNode[]; budgetLines: BudgetLine[]; locked: boolean;
}) {
  const [active, setActive] = useState<"talepler" | "rfq" | "karsilastirma" | "siparisler">("talepler");
  const [selectedRFQId, setSelectedRFQId] = useState<string | null>(null);

  function goToComparison(rfqId: string) {
    setSelectedRFQId(rfqId);
    setActive("karsilastirma");
  }

  return (
    <div className="flex flex-col gap-3">
      <Tabs
        items={[
          { key: "talepler", label: "Talepler", active: active === "talepler", onClick: () => setActive("talepler") },
          { key: "rfq", label: "RFQ", active: active === "rfq", onClick: () => setActive("rfq") },
          { key: "karsilastirma", label: "Teklif Karşılaştırma", active: active === "karsilastirma", onClick: () => setActive("karsilastirma") },
          { key: "siparisler", label: "Siparişler", active: active === "siparisler", onClick: () => setActive("siparisler") },
        ]}
      />
      <div hidden={active !== "talepler"}>
        <PurchaseRequestsTab project={project} purchaseRequests={purchaseRequests} costCodes={costCodes} wbsNodes={wbsNodes} budgetLines={budgetLines} locked={locked} />
      </div>
      <div hidden={active !== "rfq"}>
        <RFQsTab
          project={project} rfqs={rfqs} purchaseRequests={purchaseRequests} suppliers={suppliers}
          costCodes={costCodes} wbsNodes={wbsNodes} budgetLines={budgetLines} onCompare={goToComparison} locked={locked}
        />
      </div>
      <div hidden={active !== "karsilastirma"}>
        <ComparisonTab project={project} rfqs={rfqs} selectedRFQId={selectedRFQId} setSelectedRFQId={setSelectedRFQId} locked={locked} />
      </div>
      <div hidden={active !== "siparisler"}>
        <PurchaseOrdersTab project={project} purchaseOrders={purchaseOrders} suppliers={suppliers} costCodes={costCodes} wbsNodes={wbsNodes} budgetLines={budgetLines} locked={locked} />
      </div>
    </div>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { Select } from "@/components/ui/Select";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { ControlledTabPanel, ControlledTabs } from "@/components/ui/Tabs";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";
import { expenseCounts, summarizeExpenses } from "@/lib/expenses";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import { ADJUSTMENT_STATUS, BUDGET_STATUS, COMMITMENT_STATUS } from "@/lib/status";
import type {
  BudgetAdjustment,
  BudgetLine,
  Commitment,
  CostControlData,
  CostForecast,
  Expense,
  OrganizationCostCode,
  Project,
  ProjectBudget,
  WBSNode,
} from "@/lib/types";

// Maliyet Kontrolü — Sprint 2 (WBS + Cost Codes + Project Budget + Cost
// Control). Backend TÜM hesapları (revised/committed/actual/etc/eac/
// variance/forecast_profit/forecast_margin) OTORİTER olarak yapar; bu
// dosya SADECE onları görüntüler/toplar — HİÇBİR türetilmiş rakam burada
// yeniden hesaplanmaz (bkz. docs/cost-control.md).

// Manuel olmayan taahhütlerin kaynağı -- bunlar elle iptal edilemez,
// kaynak kaydın kendi akışıyla güncellenir.
const COMMITMENT_SOURCE_HINTS: Record<Exclude<Commitment["source_type"], "manual">, string> = {
  purchase_order: "Satın alma siparişinden — siparişi iptal ederek kaldırılır",
  subcontract: "Taşeron sözleşmesinden — değişiklik/fesih ile güncellenir",
};

function useCostControlAction(locked: boolean) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<unknown>) {
    if (locked) return false;
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

function costCodeLabel(cc: OrganizationCostCode) {
  return `${cc.code} — ${cc.name}${cc.is_active ? "" : " (arşivlendi)"}`;
}

// ---------- Özet ----------

function SummaryCard({ label, value, tone }: { label: string; value: string; tone?: "gold" | "success" | "danger" }) {
  return (
    <div className="flex flex-col gap-1 rounded-lg border border-border bg-surface p-4">
      <span className="text-xs uppercase tracking-widest text-text-muted">{label}</span>
      <span
        className={`text-lg font-semibold ${
          tone === "gold" ? "text-gold" : tone === "success" ? "text-success" : tone === "danger" ? "text-danger" : "text-text"
        }`}
      >
        {value}
      </span>
    </div>
  );
}

function OverviewTab({ data }: { data: CostControlData }) {
  const { summary, lines } = data;
  const marginTone = summary.forecast_profit >= 0 ? "success" : "danger";

  const totals = lines.reduce(
    (acc, l) => ({
      original: acc.original + l.original_budget,
      adjustments: acc.adjustments + l.approved_adjustments,
      revised: acc.revised + l.revised_budget,
      committed: acc.committed + l.committed_cost,
      actual: acc.actual + l.actual_cost,
      etc: acc.etc + l.etc,
      eac: acc.eac + l.eac,
      variance: acc.variance + l.variance,
    }),
    { original: 0, adjustments: 0, revised: 0, committed: 0, actual: 0, etc: 0, eac: 0, variance: 0 }
  );

  return (
    <div className="flex flex-col gap-4">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4 lg:grid-cols-7">
        <SummaryCard label="Sözleşme Bedeli" value={formatMoney(summary.contract_value, summary.currency)} />
        <SummaryCard label="Revize Bütçe" value={formatMoney(summary.revised_budget, summary.currency)} />
        <SummaryCard label="Taahhüt" value={formatMoney(summary.committed_cost, summary.currency)} />
        <SummaryCard label="Gerçekleşen" value={formatMoney(summary.actual_cost, summary.currency)} />
        <SummaryCard label="EAC (Tahmini Nihai Maliyet)" value={formatMoney(summary.eac, summary.currency)} />
        <SummaryCard
          label="Tahmini Kâr"
          value={formatMoney(summary.forecast_profit, summary.currency)}
          tone={marginTone}
        />
        <SummaryCard
          label="Tahmini Marj"
          value={`%${summary.forecast_margin_percent.toFixed(2)}`}
          tone={marginTone}
        />
      </div>

      {!summary.has_budget && (
        <p className="rounded-md border border-border bg-surface-hover px-4 py-3 text-xs text-text-muted">
          Bu proje için henüz bir bütçe oluşturulmadı — &quot;Bütçe&quot; sekmesinden oluşturabilirsiniz. Aşağıdaki
          tablo yalnızca doğrudan maliyet koduna bağlanmış (bütçe dışı) taahhüt/gider varsa satır gösterir.
        </p>
      )}

      {lines.length === 0 ? (
        <EmptyState title="Henüz maliyet hareketi yok" description="Bütçe kalemi, taahhüt veya gider eklendiğinde burada görünür." />
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>WBS</Th>
              <Th>Maliyet Kodu</Th>
              <Th>Açıklama</Th>
              <Th className="text-right">Orijinal</Th>
              <Th className="text-right">Revizyon</Th>
              <Th className="text-right">Revize</Th>
              <Th className="text-right">Taahhüt</Th>
              <Th className="text-right">Gerçekleşen</Th>
              <Th className="text-right">ETC</Th>
              <Th className="text-right">EAC</Th>
              <Th className="text-right">Varyans</Th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <Tr key={l.budget_line_id ?? `unbudgeted-${l.cost_code_id}-${i}`}>
                <Td className="text-text-muted">{l.wbs_code ?? "—"}</Td>
                <Td>
                  {l.cost_code_code} — {l.cost_code_name}
                  {l.is_unbudgeted && <Badge tone="danger">Bütçe Dışı</Badge>}
                </Td>
                <Td className="text-text-muted">{l.description || "—"}</Td>
                <Td className="text-right">{formatMoney(l.original_budget, summary.currency)}</Td>
                <Td className="text-right">{formatSignedMoney(l.approved_adjustments, summary.currency)}</Td>
                <Td className="text-right font-medium">{formatMoney(l.revised_budget, summary.currency)}</Td>
                <Td className="text-right">{formatMoney(l.committed_cost, summary.currency)}</Td>
                <Td className="text-right">{formatMoney(l.actual_cost, summary.currency)}</Td>
                <Td className="text-right">{formatMoney(l.etc, summary.currency)}</Td>
                <Td className="text-right font-medium">{formatMoney(l.eac, summary.currency)}</Td>
                <Td className={`text-right ${l.variance < 0 ? "text-danger" : "text-success"}`}>
                  {formatSignedMoney(l.variance, summary.currency)}
                </Td>
              </Tr>
            ))}
          </tbody>
          <tfoot>
            <Tr className="hover:bg-transparent font-semibold">
              <Td colSpan={3}>Toplam</Td>
              <Td className="text-right">{formatMoney(totals.original, summary.currency)}</Td>
              <Td className="text-right">{formatSignedMoney(totals.adjustments, summary.currency)}</Td>
              <Td className="text-right">{formatMoney(totals.revised, summary.currency)}</Td>
              <Td className="text-right">{formatMoney(totals.committed, summary.currency)}</Td>
              <Td className="text-right">{formatMoney(totals.actual, summary.currency)}</Td>
              <Td className="text-right">{formatMoney(totals.etc, summary.currency)}</Td>
              <Td className="text-right">{formatMoney(totals.eac, summary.currency)}</Td>
              <Td className={`text-right ${totals.variance < 0 ? "text-danger" : "text-success"}`}>
                {formatSignedMoney(totals.variance, summary.currency)}
              </Td>
            </Tr>
          </tfoot>
        </Table>
      )}
    </div>
  );
}

// ---------- WBS ----------

function WBSTab({
  project,
  wbsNodes,
  locked,
}: {
  project: Project;
  wbsNodes: WBSNode[];
  locked: boolean;
}) {
  const { busy, error, run } = useCostControlAction(locked);
  const { confirm, dialog } = useConfirmDialog();
  const [addingUnder, setAddingUnder] = useState<string | null>(null); // null => kök ekleniyor değil; "" kullanılmaz
  const [showRootForm, setShowRootForm] = useState(false);
  const [form, setForm] = useState({ code: "", name: "" });
  const [renaming, setRenaming] = useState<WBSNode | null>(null);

  const byParent = new Map<string, WBSNode[]>();
  for (const n of wbsNodes) {
    const key = n.parent_id ?? "__root__";
    const list = byParent.get(key) ?? [];
    list.push(n);
    byParent.set(key, list);
  }
  for (const list of byParent.values()) list.sort((a, b) => a.sort_order - b.sort_order || a.code.localeCompare(b.code));

  async function createNode(parentId: string | null) {
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/wbs`, {
        method: "POST",
        body: JSON.stringify({ parent_id: parentId ?? "", code: form.code, name: form.name }),
      })
    );
    if (ok) {
      setForm({ code: "", name: "" });
      setAddingUnder(null);
      setShowRootForm(false);
    }
  }

  async function rename(node: WBSNode, code: string, name: string) {
    await run(() =>
      apiClient(`/api/v1/projects/${project.id}/wbs/${node.id}`, {
        method: "PUT",
        body: JSON.stringify({ code, name, sort_order: node.sort_order }),
      })
    );
    setRenaming(null);
  }

  async function archive(node: WBSNode) {
    const ok = await confirm({
      title: "WBS Düğümünü Arşivle",
      message: `"${node.name}" (${node.code}) arşivlenecek. Bu düğüme bağlı bütçe kalemleri etkilenmez, yalnızca yeni seçimlerde gizlenir.`,
      confirmLabel: "Arşivle",
      danger: true,
    });
    if (!ok) return;
    await run(() => apiClient(`/api/v1/projects/${project.id}/wbs/${node.id}`, { method: "DELETE" }));
  }

  function renderNode(node: WBSNode, depth: number): React.ReactNode {
    const children = byParent.get(node.id) ?? [];
    return (
      <div key={node.id} className="flex flex-col gap-1">
        <div className="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-surface-hover" style={{ paddingLeft: depth * 20 + 8 }}>
          {renaming?.id === node.id ? (
            <RenameRow node={node} onSave={rename} onCancel={() => setRenaming(null)} busy={busy} />
          ) : (
            <>
              <span className={`text-sm ${!node.is_active ? "text-text-muted line-through" : ""}`}>
                <span className="font-medium">{node.code}</span> · {node.name}
              </span>
              {!node.is_active && <Badge tone="muted">Arşivlendi</Badge>}
              {node.is_active && !locked && (
                <div className="ml-auto flex items-center gap-3 text-xs">
                  <button type="button" className="text-gold hover:underline" onClick={() => setAddingUnder(node.id)}>
                    + Alt Düğüm
                  </button>
                  <button type="button" className="text-text-muted hover:underline" onClick={() => setRenaming(node)}>
                    Yeniden Adlandır
                  </button>
                  <button type="button" className="text-danger hover:underline" onClick={() => archive(node)}>
                    Arşivle
                  </button>
                </div>
              )}
            </>
          )}
        </div>
        {addingUnder === node.id && (
          <div style={{ paddingLeft: (depth + 1) * 20 + 8 }}>
            <NewNodeRow
              form={form}
              setForm={setForm}
              busy={busy}
              onSave={() => createNode(node.id)}
              onCancel={() => setAddingUnder(null)}
            />
          </div>
        )}
        {children.map((c) => renderNode(c, depth + 1))}
      </div>
    );
  }

  const roots = byParent.get("__root__") ?? [];

  return (
    <div className="flex flex-col gap-3">
      <p className="text-xs text-text-muted">
        WBS (İş Kırılım Yapısı), bütçe kalemlerini fiziksel/işlevsel gruplara ayırmak içindir — maliyet kodlarından
        (hangi TÜR maliyet) FARKLI bir eksendir (bkz. Maliyet Kodları ekranı).
      </p>
      <div className="rounded-lg border border-border bg-surface p-3">
        {roots.length === 0 && !showRootForm && (
          <p className="px-2 py-4 text-sm text-text-muted">Henüz bir WBS düğümü yok.</p>
        )}
        {roots.map((n) => renderNode(n, 0))}
        {showRootForm && (
          <NewNodeRow form={form} setForm={setForm} busy={busy} onSave={() => createNode(null)} onCancel={() => setShowRootForm(false)} />
        )}
        {!locked && !showRootForm && (
          <button type="button" onClick={() => setShowRootForm(true)} className="mt-2 text-xs text-gold hover:underline">
            + Kök Düğüm Ekle
          </button>
        )}
      </div>
      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}
    </div>
  );
}

function NewNodeRow({
  form,
  setForm,
  busy,
  onSave,
  onCancel,
}: {
  form: { code: string; name: string };
  setForm: (f: { code: string; name: string }) => void;
  busy: boolean;
  onSave: () => void;
  onCancel: () => void;
}) {
  return (
    <div className="flex flex-wrap items-end gap-2 py-2">
      <Input label="Kod" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} className="w-28" />
      <Input label="Ad" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} className="w-56" />
      <Button type="button" onClick={onSave} loading={busy} disabled={!form.code || !form.name}>
        Ekle
      </Button>
      <Button type="button" variant="ghost" onClick={onCancel}>
        Vazgeç
      </Button>
    </div>
  );
}

function RenameRow({
  node,
  onSave,
  onCancel,
  busy,
}: {
  node: WBSNode;
  onSave: (node: WBSNode, code: string, name: string) => void;
  onCancel: () => void;
  busy: boolean;
}) {
  const [code, setCode] = useState(node.code);
  const [name, setName] = useState(node.name);
  return (
    <div className="flex flex-wrap items-end gap-2">
      <Input label="Kod" value={code} onChange={(e) => setCode(e.target.value)} className="w-28" />
      <Input label="Ad" value={name} onChange={(e) => setName(e.target.value)} className="w-56" />
      <Button type="button" onClick={() => onSave(node, code, name)} loading={busy}>
        Kaydet
      </Button>
      <Button type="button" variant="ghost" onClick={onCancel}>
        Vazgeç
      </Button>
    </div>
  );
}

// ---------- Bütçe ----------

const emptyLineForm = () => ({
  wbs_node_id: "",
  cost_code_id: "",
  description: "",
  quantity: "",
  unit: "",
  unit_cost: "",
  original_amount: "",
});

function BudgetTab({
  project,
  budget,
  budgetLines,
  wbsNodes,
  costCodes,
  locked,
}: {
  project: Project;
  budget: ProjectBudget | null;
  budgetLines: BudgetLine[];
  wbsNodes: WBSNode[];
  costCodes: OrganizationCostCode[];
  locked: boolean;
}) {
  const { busy, error, run } = useCostControlAction(locked);
  const { confirm, dialog } = useConfirmDialog();
  const [formOpen, setFormOpen] = useState(false);
  const [editingLine, setEditingLine] = useState<BudgetLine | null>(null);
  const [form, setForm] = useState(emptyLineForm);
  const [adjustingLine, setAdjustingLine] = useState<BudgetLine | null>(null);

  const isDraft = budget?.status === "draft";
  const activeCostCodes = costCodes.filter((c) => c.is_active);
  const activeWbs = wbsNodes.filter((n) => n.is_active);

  async function createBudget() {
    await run(() => apiClient(`/api/v1/projects/${project.id}/budget`, { method: "POST" }));
  }

  async function baseline() {
    const ok = await confirm({
      title: "Bütçeyi Baseline Al",
      message:
        "Baseline alındıktan sonra kalemlerin orijinal tutarları KALICI olarak sabitlenir — bundan sonraki her değişiklik bir \"Bütçe Revizyonu\" olarak kaydedilmelidir. Bu işlem GERİ ALINAMAZ.",
      confirmLabel: "Baseline Al",
      danger: true,
    });
    if (!ok) return;
    await run(() => apiClient(`/api/v1/projects/${project.id}/budget/baseline`, { method: "POST" }));
  }

  function openCreate() {
    setEditingLine(null);
    setForm(emptyLineForm());
    setFormOpen(true);
  }

  function openEdit(line: BudgetLine) {
    setEditingLine(line);
    setForm({
      wbs_node_id: line.wbs_node_id ?? "",
      cost_code_id: line.cost_code_id,
      description: line.description,
      quantity: line.quantity != null ? String(line.quantity) : "",
      unit: line.unit ?? "",
      unit_cost: line.unit_cost != null ? String(line.unit_cost) : "",
      original_amount: String(line.original_amount),
    });
    setFormOpen(true);
  }

  async function submitLine(e: FormEvent) {
    e.preventDefault();
    const payload = {
      wbs_node_id: form.wbs_node_id,
      cost_code_id: form.cost_code_id,
      description: form.description,
      quantity: form.quantity ? Number(form.quantity) : null,
      unit: form.unit,
      unit_cost: form.unit_cost ? Number(form.unit_cost) : null,
      original_amount: Number(form.original_amount || 0),
    };
    const ok = await run(() =>
      editingLine
        ? apiClient(`/api/v1/projects/${project.id}/budget/lines/${editingLine.id}`, {
            method: "PUT",
            body: JSON.stringify(payload),
          })
        : apiClient(`/api/v1/projects/${project.id}/budget/lines`, { method: "POST", body: JSON.stringify(payload) })
    );
    if (ok) setFormOpen(false);
  }

  async function deleteLine(line: BudgetLine) {
    const ok = await confirm({
      title: "Bütçe Kalemini Sil",
      message: `"${line.description}" kalemi silinecek.`,
      confirmLabel: "Sil",
      danger: true,
    });
    if (!ok) return;
    await run(() => apiClient(`/api/v1/projects/${project.id}/budget/lines/${line.id}`, { method: "DELETE" }));
  }

  if (!budget) {
    return (
      <EmptyState
        title="Bu proje için henüz bir bütçe yok"
        description="Bütçe oluşturduktan sonra kalem ekleyebilir, baseline alabilir ve revizyon yönetebilirsiniz."
        action={
          !locked && (
            <Button onClick={createBudget} disabled={busy}>
              Bütçe Oluştur
            </Button>
          )
        }
      />
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between rounded-lg border border-border bg-surface p-3">
        <div className="flex items-center gap-3 text-sm">
          <StatusBadge status={budget.status} registry={BUDGET_STATUS} />
          <span className="text-text-muted">
            {isDraft
              ? "Taslak — kalemler serbestçe düzenlenebilir."
              : "Baseline alındı — kalem tutarları sabit, değişiklikler Bütçe Revizyonu ile yapılır."}
          </span>
        </div>
        <div className="flex gap-2">
          {isDraft && !locked && (
            <>
              <Button variant="secondary" onClick={openCreate}>
                + Kalem Ekle
              </Button>
              <Button onClick={baseline} disabled={busy || budgetLines.length === 0}>
                Baseline Al
              </Button>
            </>
          )}
        </div>
      </div>

      {budgetLines.length === 0 ? (
        <EmptyState title="Henüz bütçe kalemi yok" description={isDraft ? "Yukarıdan yeni bir kalem ekleyin." : undefined} />
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>WBS</Th>
              <Th>Maliyet Kodu</Th>
              <Th>Açıklama</Th>
              <Th className="text-right">Miktar × Birim Fiyat</Th>
              <Th className="text-right">Orijinal Tutar</Th>
              <Th className="w-40" />
            </tr>
          </thead>
          <tbody>
            {budgetLines.map((l) => (
              <Tr key={l.id}>
                <Td className="text-text-muted">{l.wbs_code ?? "—"}</Td>
                <Td>
                  {l.cost_code_code} — {l.cost_code_name}
                </Td>
                <Td>{l.description}</Td>
                <Td className="text-right text-text-muted">
                  {l.quantity != null && l.unit_cost != null
                    ? `${l.quantity} ${l.unit ?? ""} × ${formatMoney(l.unit_cost, project.currency)}`
                    : "—"}
                </Td>
                <Td className="text-right font-medium">{formatMoney(l.original_amount, project.currency)}</Td>
                <Td className="text-right">
                  <div className="flex justify-end gap-3 text-xs">
                    {isDraft && !locked ? (
                      <>
                        <button type="button" className="text-gold hover:underline" onClick={() => openEdit(l)}>
                          Düzenle
                        </button>
                        <button type="button" className="text-danger hover:underline" onClick={() => deleteLine(l)}>
                          Sil
                        </button>
                      </>
                    ) : (
                      !locked && (
                        <button type="button" className="text-gold hover:underline" onClick={() => setAdjustingLine(l)}>
                          Revize Et
                        </button>
                      )
                    )}
                  </div>
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}

      <Modal open={formOpen} onClose={() => setFormOpen(false)} title={editingLine ? "Bütçe Kalemini Düzenle" : "Yeni Bütçe Kalemi"}>
        <form onSubmit={submitLine} className="flex flex-col gap-3">
          <Select
            label="WBS (opsiyonel)"
            value={form.wbs_node_id}
            onChange={(e) => setForm({ ...form, wbs_node_id: e.target.value })}
          >
            <option value="">Yok</option>
            {activeWbs.map((n) => (
              <option key={n.id} value={n.id}>
                {n.code} — {n.name}
              </option>
            ))}
          </Select>
          <Select
            label="Maliyet Kodu"
            required
            value={form.cost_code_id}
            onChange={(e) => setForm({ ...form, cost_code_id: e.target.value })}
          >
            <option value="">Seçin…</option>
            {activeCostCodes.map((c) => (
              <option key={c.id} value={c.id}>
                {costCodeLabel(c)}
              </option>
            ))}
          </Select>
          <Input
            label="Açıklama"
            required
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <div className="grid grid-cols-3 gap-3">
            <Input
              label="Miktar (opsiyonel)"
              type="number"
              step="0.01"
              value={form.quantity}
              onChange={(e) => setForm({ ...form, quantity: e.target.value })}
            />
            <Input label="Birim" value={form.unit} onChange={(e) => setForm({ ...form, unit: e.target.value })} />
            <Input
              label="Birim Fiyat (opsiyonel)"
              type="number"
              step="0.01"
              value={form.unit_cost}
              onChange={(e) => setForm({ ...form, unit_cost: e.target.value })}
            />
          </div>
          <Input
            label={`Orijinal Tutar (${project.currency}) — miktar × birim fiyat girilirse YOK SAYILIR`}
            type="number"
            step="0.01"
            value={form.original_amount}
            onChange={(e) => setForm({ ...form, original_amount: e.target.value })}
          />
          <p className="text-xs text-text-muted">
            Miktar ve birim fiyatın İKİSİ de girilirse, tutar backend tarafından otomatik hesaplanır.
          </p>
          <div className="flex gap-2 border-t border-border pt-3">
            <Button type="submit" loading={busy}>
              Kaydet
            </Button>
            <Button type="button" variant="ghost" onClick={() => setFormOpen(false)}>
              Vazgeç
            </Button>
          </div>
        </form>
      </Modal>

      {adjustingLine && (
        <AdjustmentModal
          project={project}
          line={adjustingLine}
          onClose={() => setAdjustingLine(null)}
          currency={project.currency}
        />
      )}
      {dialog}
    </div>
  );
}

function AdjustmentModal({
  project,
  line,
  onClose,
  currency,
}: {
  project: Project;
  line: BudgetLine;
  onClose: () => void;
  currency: string;
}) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await apiClient(`/api/v1/projects/${project.id}/budget/adjustments`, {
        method: "POST",
        body: JSON.stringify({ budget_line_id: line.id, amount: Number(amount), reason }),
      });
      router.refresh();
      onClose();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={onClose} title={`Bütçe Revizyonu — ${line.description}`}>
      <form onSubmit={submit} className="flex flex-col gap-3">
        <p className="text-xs text-text-muted">
          Bu bütçe baseline alındığı için orijinal tutar değiştirilemez. Bunun yerine bir revizyon (adjustment)
          oluşturun — yalnızca ONAYLANDIKTAN sonra revize bütçeyi etkiler.
        </p>
        <Input
          label={`Revizyon Tutarı (${currency}) — azaltmak için negatif girin`}
          type="number"
          step="0.01"
          required
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        <Textarea label="Gerekçe" required className="min-h-16" value={reason} onChange={(e) => setReason(e.target.value)} />
        {error && <p className="text-xs text-danger">{error}</p>}
        <div className="flex gap-2 border-t border-border pt-3">
          <Button type="submit" loading={busy}>
            Revizyon Oluştur
          </Button>
          <Button type="button" variant="ghost" onClick={onClose}>
            Vazgeç
          </Button>
        </div>
      </form>
    </Modal>
  );
}

export function AdjustmentsSection({
  project,
  adjustments,
  budgetLines,
  locked,
}: {
  project: Project;
  adjustments: BudgetAdjustment[];
  budgetLines: BudgetLine[];
  locked: boolean;
}) {
  const { busy, error, run } = useCostControlAction(locked);
  const lineById = new Map(budgetLines.map((l) => [l.id, l]));

  if (adjustments.length === 0) {
    return <p className="text-sm text-text-muted">Henüz bir bütçe revizyonu oluşturulmadı.</p>;
  }

  return (
    <div className="flex flex-col gap-3">
      <Table>
        <thead>
          <tr>
            <Th>Bütçe Kalemi</Th>
            <Th className="text-right">Tutar</Th>
            <Th>Gerekçe</Th>
            <Th>Durum</Th>
            <Th className="w-32" />
          </tr>
        </thead>
        <tbody>
          {adjustments.map((a) => (
            <Tr key={a.id}>
              <Td>{lineById.get(a.budget_line_id)?.description ?? "—"}</Td>
              <Td className={`text-right ${a.amount < 0 ? "text-danger" : "text-success"}`}>
                {formatSignedMoney(a.amount, project.currency)}
              </Td>
              <Td className="text-text-muted">{a.reason}</Td>
              <Td>
                <StatusBadge status={a.status} registry={ADJUSTMENT_STATUS} />
              </Td>
              <Td className="text-right">
                {a.status === "draft" && !locked && (
                  <div className="flex justify-end gap-3 text-xs">
                    <button
                      type="button"
                      className="text-success hover:underline"
                      disabled={busy}
                      onClick={() =>
                        run(() =>
                          apiClient(`/api/v1/projects/${project.id}/budget/adjustments/${a.id}/approve`, { method: "POST" })
                        )
                      }
                    >
                      Onayla
                    </button>
                    <button
                      type="button"
                      className="text-danger hover:underline"
                      disabled={busy}
                      onClick={() =>
                        run(() =>
                          apiClient(`/api/v1/projects/${project.id}/budget/adjustments/${a.id}/reject`, { method: "POST" })
                        )
                      }
                    >
                      Reddet
                    </button>
                  </div>
                )}
              </Td>
            </Tr>
          ))}
        </tbody>
      </Table>
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Taahhütler (Commitments) ----------

const emptyCommitmentForm = () => ({
  cost_code_id: "",
  budget_line_id: "",
  description: "",
  committed_amount: "",
  committed_at: new Date().toISOString().slice(0, 10),
});

function CommitmentsTab({
  project,
  commitments,
  budgetLines,
  costCodes,
  locked,
}: {
  project: Project;
  commitments: Commitment[];
  budgetLines: BudgetLine[];
  costCodes: OrganizationCostCode[];
  locked: boolean;
}) {
  const { busy, error, run } = useCostControlAction(locked);
  const { confirm, dialog } = useConfirmDialog();
  const [formOpen, setFormOpen] = useState(false);
  const [form, setForm] = useState(emptyCommitmentForm);
  const activeCostCodes = costCodes.filter((c) => c.is_active);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/commitments`, {
        method: "POST",
        body: JSON.stringify({
          cost_code_id: form.cost_code_id,
          budget_line_id: form.budget_line_id,
          description: form.description,
          committed_amount: Number(form.committed_amount),
          committed_at: form.committed_at,
        }),
      })
    );
    if (ok) {
      setForm(emptyCommitmentForm());
      setFormOpen(false);
    }
  }

  async function voidCommitment(c: Commitment) {
    const ok = await confirm({
      title: "Taahhüdü İptal Et",
      message: `"${c.description}" (${formatMoney(c.committed_amount, c.currency)}) taahhüdü iptal edilecek — bu tutar artık taahhüt toplamına dahil edilmeyecek.`,
      confirmLabel: "İptal Et",
      danger: true,
    });
    if (!ok) return;
    const reason = prompt("İptal nedeni:") ?? "";
    await run(() =>
      apiClient(`/api/v1/projects/${project.id}/commitments/${c.id}/void`, {
        method: "POST",
        body: JSON.stringify({ reason }),
      })
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-start justify-between gap-3 rounded-md border border-border bg-surface-hover px-4 py-3">
        <p className="text-xs text-text-muted">
          <span className="font-semibold text-text">Manuel Taahhüt:</span> Bu, resmi bir satın alma siparişi veya
          taşeron sözleşmesi DEĞİLDİR — yalnızca sahada bilinen ama henüz masraf olarak girilmemiş bir maliyet
          taahhüdünü kayıt altına almak içindir. Satınalma/taşeron modülleri gelecek bir sprintte eklenecektir.
        </p>
        {!locked && <Button onClick={() => setFormOpen(true)}>+ Manuel Taahhüt</Button>}
      </div>

      {commitments.length === 0 ? (
        <EmptyState title="Henüz taahhüt yok" />
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Tarih</Th>
              <Th>Maliyet Kodu</Th>
              <Th>Açıklama</Th>
              <Th className="text-right">Tutar</Th>
              <Th>Durum</Th>
              <Th className="w-24" />
            </tr>
          </thead>
          <tbody>
            {commitments.map((c) => (
              <Tr key={c.id} className={c.status === "voided" ? "opacity-50" : ""}>
                <Td className="text-text-muted">{new Date(c.committed_at).toLocaleDateString("tr-TR")}</Td>
                <Td>
                  {c.cost_code_code} — {c.cost_code_name}
                </Td>
                <Td>
                  {c.description}
                  {c.source_type !== "manual" && (
                    <div className="text-xs text-text-muted">{COMMITMENT_SOURCE_HINTS[c.source_type]}</div>
                  )}
                  {c.void_reason && <div className="text-xs text-danger">İptal: {c.void_reason}</div>}
                </Td>
                <Td className={`text-right ${c.status === "voided" ? "line-through" : "font-medium"}`}>
                  {formatMoney(c.committed_amount, c.currency)}
                </Td>
                <Td>
                  <StatusBadge status={c.status} registry={COMMITMENT_STATUS} />
                </Td>
                <Td className="text-right">
                  {/* Yalnızca manuel taahhüt elle iptal edilir; sipariş/taşeron
                      taahhüdü kaynağıyla senkron tutulur (backend de reddeder). */}
                  {c.status === "active" && c.source_type === "manual" && !locked && (
                    <button type="button" className="text-xs text-danger hover:underline" onClick={() => voidCommitment(c)}>
                      İptal Et
                    </button>
                  )}
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}

      <Modal open={formOpen} onClose={() => setFormOpen(false)} title="Yeni Manuel Taahhüt">
        <form onSubmit={submit} className="flex flex-col gap-3">
          <Select
            label="Bütçe Kalemi (opsiyonel)"
            value={form.budget_line_id}
            onChange={(e) => {
              const line = budgetLines.find((l) => l.id === e.target.value);
              setForm({ ...form, budget_line_id: e.target.value, cost_code_id: line ? line.cost_code_id : form.cost_code_id });
            }}
          >
            <option value="">Bağlı değil (bütçe dışı)</option>
            {budgetLines.map((l) => (
              <option key={l.id} value={l.id}>
                {l.description} ({l.cost_code_code})
              </option>
            ))}
          </Select>
          <Select
            label="Maliyet Kodu"
            required
            value={form.cost_code_id}
            disabled={!!form.budget_line_id}
            onChange={(e) => setForm({ ...form, cost_code_id: e.target.value })}
          >
            <option value="">Seçin…</option>
            {activeCostCodes.map((c) => (
              <option key={c.id} value={c.id}>
                {costCodeLabel(c)}
              </option>
            ))}
          </Select>
          <Input
            label="Açıklama"
            required
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label={`Tutar (${project.currency})`}
              type="number"
              step="0.01"
              min="0"
              required
              value={form.committed_amount}
              onChange={(e) => setForm({ ...form, committed_amount: e.target.value })}
            />
            <DateInput
              label="Tarih"
              required
              value={form.committed_at}
              onChange={(e) => setForm({ ...form, committed_at: e.target.value })}
            />
          </div>
          <div className="flex gap-2 border-t border-border pt-3">
            <Button type="submit" loading={busy}>
              Kaydet
            </Button>
            <Button type="button" variant="ghost" onClick={() => setFormOpen(false)}>
              Vazgeç
            </Button>
          </div>
        </form>
      </Modal>
      {dialog}
    </div>
  );
}

// ---------- Gerçekleşen (mevcut masraf verisinin maliyet koduna göre kırılımı) ----------

function ActualCostTab({ expenses, costCodes }: { expenses: Expense[]; costCodes: OrganizationCostCode[] }) {
  const codeById = new Map(costCodes.map((c) => [c.id, c]));
  // Gerçekleşen yalnızca ONAYLI masraflardan (backend migration 0060, EAC
  // ile aynı kural); onay bekleyenler yalnızca not olarak sayılır.
  const counted = expenses.filter(expenseCounts);
  const mapped = counted.filter((e) => e.cost_code_id);
  const unmapped = counted.filter((e) => !e.cost_code_id);
  const { pendingCount } = summarizeExpenses(expenses);
  const pendingNote = pendingCount > 0 && (
    <p className="text-xs text-text-muted">
      {pendingCount} masraf onay bekliyor — onaylanınca gerçekleşen maliyete girer.
    </p>
  );

  if (counted.length === 0) {
    return (
      <div className="flex flex-col gap-3">
        <EmptyState title="Henüz gider kaydı yok" description="Gerçekleşen maliyet, Finans > Masraflar bölümünde girilip onaylanan kayıtlardan gelir." />
        {pendingNote}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-xs text-text-muted">
        Bu tablo, Finans &gt; Masraflar bölümünde girilen ve onaylanan kayıtların maliyet koduna göre kırılımıdır —
        AYRI bir gerçekleşen-maliyet kaydı DEĞİLDİR (spec: tek gerçek kaynak, mükerrer kayıt yok).
      </p>
      {pendingNote}
      {mapped.length > 0 && (
        <Table>
          <thead>
            <tr>
              <Th>Tarih</Th>
              <Th>Maliyet Kodu</Th>
              <Th>Açıklama</Th>
              <Th className="text-right">Tutar</Th>
            </tr>
          </thead>
          <tbody>
            {mapped.map((e) => (
              <Tr key={e.id}>
                <Td className="text-text-muted">{new Date(e.expense_date).toLocaleDateString("tr-TR")}</Td>
                <Td>{e.cost_code_id ? (codeById.get(e.cost_code_id)?.code ?? "—") : "—"}</Td>
                <Td>{e.description}</Td>
                <Td className="text-right font-medium">{formatMoney(e.amount, e.currency)}</Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}
      {unmapped.length > 0 && (
        <div className="rounded-md border border-border bg-surface-hover p-3 text-xs text-text-muted">
          {unmapped.length} masraf kaydı henüz bir maliyet koduna eşlenmemiş — Finans &gt; Masraflar bölümünden
          düzenleyerek maliyet kodu ekleyebilirsiniz.
        </div>
      )}
    </div>
  );
}

// ---------- Tahmin (ETC) ----------

function ForecastTab({
  project,
  budgetLines,
  forecasts,
  data,
  locked,
}: {
  project: Project;
  budgetLines: BudgetLine[];
  forecasts: CostForecast[];
  data: CostControlData;
  locked: boolean;
}) {
  const { busy, error, run } = useCostControlAction(locked);
  const forecastByLine = new Map(forecasts.map((f) => [f.budget_line_id, f]));
  const lineByCC = new Map(data.lines.filter((l) => l.budget_line_id).map((l) => [l.budget_line_id as string, l]));

  if (budgetLines.length === 0) {
    return <EmptyState title="Tahmin girilecek bir bütçe kalemi yok" />;
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-xs text-text-muted">
        ETC (Estimate To Complete), her kalem için &quot;bitirmek üzere kalan tahmini maliyet&quot;tir — girilmezse
        backend varsayılan olarak (Revize Bütçe − Gerçekleşen, negatif olamaz) önerir. EAC = Gerçekleşen + ETC.
      </p>
      <Table>
        <thead>
          <tr>
            <Th>Bütçe Kalemi</Th>
            <Th className="text-right">Gerçekleşen</Th>
            <Th className="text-right">ETC</Th>
            <Th className="text-right">EAC</Th>
            <Th className="w-56" />
          </tr>
        </thead>
        <tbody>
          {budgetLines.map((l) => {
            const override = forecastByLine.get(l.id);
            const ccLine = lineByCC.get(l.id);
            return (
              <ForecastRow
                key={l.id}
                project={project}
                line={l}
                override={override}
                actual={ccLine?.actual_cost ?? 0}
                eac={ccLine?.eac ?? 0}
                busy={busy}
                run={run}
                locked={locked}
              />
            );
          })}
        </tbody>
      </Table>
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

function ForecastRow({
  project,
  line,
  override,
  actual,
  eac,
  busy,
  run,
  locked,
}: {
  project: Project;
  line: BudgetLine;
  override?: CostForecast;
  actual: number;
  eac: number;
  busy: boolean;
  run: (fn: () => Promise<unknown>) => Promise<boolean | undefined>;
  locked: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const [etc, setEtc] = useState(override ? String(override.etc_amount) : "");
  const [note, setNote] = useState(override?.note ?? "");

  async function save() {
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/budget/lines/${line.id}/forecast`, {
        method: "PUT",
        body: JSON.stringify({ etc_amount: Number(etc || 0), note }),
      })
    );
    if (ok) setEditing(false);
  }

  return (
    <Tr>
      <Td>{line.description}</Td>
      <Td className="text-right text-text-muted">{formatMoney(actual, project.currency)}</Td>
      <Td className="text-right">
        {editing ? (
          <Input type="number" step="0.01" value={etc} onChange={(e) => setEtc(e.target.value)} className="w-32 text-right" />
        ) : override ? (
          formatMoney(override.etc_amount, project.currency)
        ) : (
          <span className="text-text-muted">varsayılan</span>
        )}
      </Td>
      <Td className="text-right font-medium">{formatMoney(eac, project.currency)}</Td>
      <Td className="text-right">
        {!locked &&
          (editing ? (
            <div className="flex justify-end gap-2">
              <Input placeholder="Not (opsiyonel)" value={note} onChange={(e) => setNote(e.target.value)} className="w-32" />
              <Button type="button" onClick={save} loading={busy}>
                Kaydet
              </Button>
              <Button type="button" variant="ghost" onClick={() => setEditing(false)}>
                Vazgeç
              </Button>
            </div>
          ) : (
            <button type="button" className="text-xs text-gold hover:underline" onClick={() => setEditing(true)}>
              {override ? "Düzenle" : "Manuel ETC Gir"}
            </button>
          ))}
      </Td>
    </Tr>
  );
}

// ---------- Workspace (dış katman) ----------

export function CostControlWorkspace({
  project,
  data,
  budget,
  budgetLines,
  wbsNodes,
  costCodes,
  adjustments,
  commitments,
  forecasts,
  expenses,
  locked,
}: {
  project: Project;
  data: CostControlData;
  budget: ProjectBudget | null;
  budgetLines: BudgetLine[];
  wbsNodes: WBSNode[];
  costCodes: OrganizationCostCode[];
  adjustments: BudgetAdjustment[];
  commitments: Commitment[];
  forecasts: CostForecast[];
  expenses: Expense[];
  locked: boolean;
}) {
  return (
    <ControlledTabs
      defaultTab="ozet"
      items={[
        { key: "ozet", label: "Özet" },
        { key: "butce", label: "Bütçe" },
        { key: "taahhutler", label: "Taahhütler" },
        { key: "gerceklesen", label: "Gerçekleşen" },
        { key: "tahmin", label: "Tahmin" },
      ]}
    >
      <ControlledTabPanel tab="ozet">
        <OverviewTab data={data} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="butce">
        <div className="flex flex-col gap-6">
          <WBSTab project={project} wbsNodes={wbsNodes} locked={locked} />
          <div className="border-t border-border pt-4">
            <BudgetTab
              project={project}
              budget={budget}
              budgetLines={budgetLines}
              wbsNodes={wbsNodes}
              costCodes={costCodes}
              locked={locked}
            />
          </div>
          {budget && budget.status === "baselined" && (
            <div className="border-t border-border pt-4">
              <h3 className="mb-3 text-xs font-semibold uppercase tracking-widest text-text-muted">Bütçe Revizyonları</h3>
              <AdjustmentsSection project={project} adjustments={adjustments} budgetLines={budgetLines} locked={locked} />
            </div>
          )}
        </div>
      </ControlledTabPanel>
      <ControlledTabPanel tab="taahhutler">
        <CommitmentsTab project={project} commitments={commitments} budgetLines={budgetLines} costCodes={costCodes} locked={locked} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="gerceklesen">
        <ActualCostTab expenses={expenses} costCodes={costCodes} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="tahmin">
        <ForecastTab project={project} budgetLines={budgetLines} forecasts={forecasts} data={data} locked={locked} />
      </ControlledTabPanel>
    </ControlledTabs>
  );
}

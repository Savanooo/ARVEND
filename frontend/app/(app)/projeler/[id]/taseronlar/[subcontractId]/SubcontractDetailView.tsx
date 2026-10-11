"use client";

import Link from "next/link";

import { Section } from "@/components/ui/Accordion";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import { buttonClass } from "@/components/ui/styles";
import { apiClient } from "@/lib/api";
import { formatMoney, formatPercent, formatSignedMoney } from "@/lib/format";
import { COMMITMENT_STATUS } from "@/lib/status";
import {
  round2,
  subcontractActions,
  SUBCONTRACT_STATUS,
  type ProgressClaim,
  type SubcontractChangeOrder,
  type SubcontractDetail,
  type SubcontractPayment,
  type SubcontractPerms,
} from "@/lib/subcontracts";
import type { BudgetLine, OrganizationCostCode, Project, WBSNode } from "@/lib/types";

import { costCodeLabel, Field, formatDay, formatTs, StatusPill, useSubcontractAction } from "../shared";
import { ChangeOrdersPanel } from "./ChangeOrdersPanel";
import { ClaimsPanel } from "./ClaimsPanel";
import { PaymentsPanel } from "./PaymentsPanel";

// Hiyerarşi mobil ile aynı: Başlık + yaşam döngüsü -> Ticari Özet -> Kalemler
// (SOV) -> Hakedişler -> Değişiklik Emirleri -> Ödemeler. Hiçbir toplam burada
// yeniden hesaplanmaz; backend'in current_value'su yalnızca düzenlenir.
// Taahhüt ekseni (sertifikalı / kalan taahhüt) hakediş okuma, nakit ekseni
// (ödenen / kalan ödenecek) ödeme okuma izniyle görünür.

export function SubcontractDetailView({
  project,
  detail,
  changeOrders,
  claims,
  payments,
  costCodes,
  budgetLines,
  wbsNodes,
  perms,
  locked,
  focusClaimId,
  focusChangeOrderId,
}: {
  project: Project;
  detail: SubcontractDetail;
  changeOrders: SubcontractChangeOrder[] | null;
  claims: ProgressClaim[] | null;
  payments: SubcontractPayment[] | null;
  costCodes: OrganizationCostCode[] | null;
  budgetLines: BudgetLine[] | null;
  wbsNodes: WBSNode[] | null;
  perms: SubcontractPerms;
  locked: boolean;
  focusClaimId: string | null;
  focusChangeOrderId: string | null;
}) {
  const sc = detail.subcontract;
  const value = detail.current_value;
  const currency = sc.currency;
  const actions = subcontractActions(sc.status, perms, locked);
  const { busy, error, run } = useSubcontractAction(locked);
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const { askReason, dialog: reasonDialog } = useReasonDialog();
  const scBase = `/api/v1/projects/${project.id}/subcontracts/${sc.id}`;

  const costCodeById = new Map((costCodes ?? []).map((c) => [c.id, c]));
  const budgetLineById = new Map((budgetLines ?? []).map((l) => [l.id, l]));

  async function activate() {
    const ok = await confirm({
      title: "Sözleşmeyi Aktifleştir",
      message:
        "Bu taşeron sözleşmesi aktifleştirilsin mi? Ticari şartlar ve kalemler kilitlenir, kalemler Maliyet Kontrolü'nde taahhüt olarak görünür. Sonraki değişiklikler değişiklik emriyle yapılır.",
      confirmLabel: "Aktifleştir",
    });
    if (!ok) return;
    if (await run(() => apiClient(`${scBase}/activate`, { method: "POST" }))) toast.success(`${sc.subcontract_no} aktifleştirildi.`);
  }

  async function cancel() {
    const reason = await askReason({
      title: "Sözleşmeyi İptal Et",
      message: `${sc.subcontract_no} (taslak) iptal edilecek. Bu işlem geri alınamaz.`,
      label: "İptal nedeni",
      confirmLabel: "İptal Et",
      danger: true,
      required: true,
    });
    if (reason === null) return;
    if (await run(() => apiClient(`${scBase}/cancel`, { method: "POST", body: JSON.stringify({ reason }) })))
      toast.success("Sözleşme iptal edildi.");
  }

  async function complete() {
    const ok = await confirm({
      title: "Sözleşmeyi Tamamla",
      message:
        "Bu taşeron sözleşmesi tamamlandı olarak işaretlensin mi? Taahhüt değişmez; sertifikalı hakedişlerin ödemeleri girilmeye devam edebilir.",
      confirmLabel: "Tamamla",
    });
    if (!ok) return;
    if (await run(() => apiClient(`${scBase}/complete`, { method: "POST" }))) toast.success("Sözleşme tamamlandı.");
  }

  async function terminate() {
    const reason = await askReason({
      title: "Sözleşmeyi Feshet",
      message:
        "Aktif sözleşme feshedilecek: sertifikalı hakediş tutarı taahhüt olarak kalır, kalan kısım serbest bırakılır. Bu işlem geri alınamaz.",
      label: "Fesih nedeni",
      confirmLabel: "Feshet",
      danger: true,
      required: true,
    });
    if (reason === null) return;
    if (await run(() => apiClient(`${scBase}/terminate`, { method: "POST", body: JSON.stringify({ reason }) })))
      toast.success("Sözleşme feshedildi.");
  }

  const approvedNet = round2(value.approved_additions - value.approved_deductions);
  const pendingNet = round2(value.pending_additions - value.pending_deductions);
  const hasLifecycle = actions.edit || actions.activate || actions.cancel || actions.complete || actions.terminate;

  return (
    <div className="flex flex-col gap-6 p-8">
      {locked && (
        <p className="rounded-md border border-border bg-surface px-3 py-2 text-xs text-text-muted">
          Proje tamamlandı ya da iptal edildi; taşeron işlemleri kilitli. Kayıtlar yalnızca görüntülenebilir.
        </p>
      )}

      {/* Başlık + yaşam döngüsü */}
      <div className="flex flex-col gap-4 rounded-lg border border-border bg-surface p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-3">
              <StatusPill registry={SUBCONTRACT_STATUS} status={sc.status} />
              <span className="text-sm text-text-muted">
                {sc.status === "draft" && "Taslak — kalemler ve şartlar serbestçe düzenlenebilir."}
                {sc.status === "active" && "Aktif — ticari taban kilitli, değişiklikler değişiklik emriyle yapılır."}
                {sc.status === "completed" && `Tamamlandı (${formatTs(sc.completed_at)}).`}
                {sc.status === "cancelled" && `İptal edildi${sc.cancel_reason ? ` — ${sc.cancel_reason}` : ""}.`}
                {sc.status === "terminated" &&
                  `Feshedildi${sc.termination_reason ? ` — ${sc.termination_reason}` : ""}.`}
              </span>
            </div>
            {sc.title && <p className="text-base font-semibold">{sc.title}</p>}
            {sc.scope_summary && <p className="whitespace-pre-line text-sm text-text-muted">{sc.scope_summary}</p>}
          </div>
          {hasLifecycle && (
            <div className="flex flex-wrap gap-2">
              {actions.edit && (
                <Link href={`/projeler/${project.id}/taseronlar/${sc.id}/duzenle`} className={buttonClass("secondary")}>
                  Düzenle
                </Link>
              )}
              {actions.activate && (
                <Button type="button" disabled={busy} onClick={activate}>
                  Aktifleştir
                </Button>
              )}
              {actions.complete && (
                <Button type="button" disabled={busy} onClick={complete}>
                  Tamamla
                </Button>
              )}
              {actions.cancel && (
                <Button type="button" variant="danger" disabled={busy} onClick={cancel}>
                  İptal Et
                </Button>
              )}
              {actions.terminate && (
                <Button type="button" variant="danger" disabled={busy} onClick={terminate}>
                  Feshet
                </Button>
              )}
            </div>
          )}
        </div>
        {error && <p className="text-xs text-danger">{error}</p>}
        <div className="grid grid-cols-2 gap-4 border-t border-border pt-4 text-sm md:grid-cols-4">
          <Field label="Taşeron" value={sc.supplier_name || sc.supplier_code || "—"} />
          <Field label="Yürürlük" value={formatDay(sc.effective_date)} />
          <Field label="Başlangıç" value={formatDay(sc.start_date)} />
          <Field label="Planlanan Bitiş" value={formatDay(sc.planned_completion_date)} />
          <Field
            label="Hakediş Kesintisi"
            value={sc.retention_percent === null || sc.retention_percent === undefined ? "—" : formatPercent(sc.retention_percent)}
          />
          <Field
            label="Avans Tutarı"
            value={sc.advance_amount === null || sc.advance_amount === undefined ? "—" : formatMoney(sc.advance_amount, currency)}
          />
          <Field label="Ödeme Koşulları" value={sc.payment_terms || "—"} />
          <Field label="Aktifleştirme" value={formatTs(sc.activated_at)} />
        </div>
        {sc.notes && (
          <div className="border-t border-border pt-4 text-sm">
            <Field label="Notlar" value={<span className="whitespace-pre-line">{sc.notes}</span>} />
          </div>
        )}
      </div>

      {/* Ticari Özet */}
      <Section title="Ticari Özet" defaultOpen>
        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <Field
              label="Güncel Değer"
              value={<span className="font-semibold text-gold">{formatMoney(value.current_value, currency)}</span>}
            />
            <Field label="Orijinal Sözleşme" value={formatMoney(value.original_amount, currency)} />
            <Field
              label="Onaylı Ek İş / Kesinti (net)"
              value={
                <span className={approvedNet > 0 ? "text-success" : approvedNet < 0 ? "text-danger" : ""}>
                  {formatSignedMoney(approvedNet, currency)}
                </span>
              }
            />
            {(value.pending_additions !== 0 || value.pending_deductions !== 0) && (
              <Field
                label="Onay Bekleyen (net)"
                value={<span className="text-text-muted">{formatSignedMoney(pendingNet, currency)}</span>}
              />
            )}
          </div>
          {(perms.canReadClaims || perms.canReadPayments) && (
            <div className="grid grid-cols-2 gap-4 border-t border-border pt-4 md:grid-cols-4">
              {perms.canReadClaims && (
                <>
                  <Field label="Sertifikalı Toplam" value={formatMoney(value.certified_to_date, currency)} />
                  <Field label="Kalan Taahhüt" value={formatMoney(value.remaining_commitment, currency)} />
                </>
              )}
              {perms.canReadPayments && (
                <>
                  <Field label="Ödenen Toplam" value={<span className="text-success">{formatMoney(value.paid_to_date, currency)}</span>} />
                  <Field
                    label="Kalan Ödenecek"
                    value={<span className="font-semibold">{formatMoney(value.remaining_payable, currency)}</span>}
                  />
                </>
              )}
              {perms.canReadClaims && perms.canReadPayments && (
                <Field
                  label="Sertifikalı, Ödenmemiş"
                  value={(() => {
                    const unpaid = round2(value.certified_to_date - value.paid_to_date);
                    return <span className={unpaid > 0 ? "text-danger" : ""}>{formatMoney(unpaid, currency)}</span>;
                  })()}
                />
              )}
            </div>
          )}
          <p className="text-xs text-text-muted">
            Sertifika edilmiş olmak ödendiği anlamına gelmez; gerçek ödemeler aşağıdaki Ödemeler bölümündedir.
          </p>
        </div>
      </Section>

      {/* SOV */}
      <Section title="Kalemler (SOV)" defaultOpen>
        {detail.items.length === 0 ? (
          <p className="text-text-muted">Kalem yok.</p>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Açıklama</Th>
                <Th>Maliyet Kodu</Th>
                <Th>Bütçe Kalemi</Th>
                <Th className="text-right">Miktar</Th>
                <Th className="text-right">Birim Fiyat</Th>
                <Th className="text-right">Tutar</Th>
              </tr>
            </thead>
            <tbody>
              {detail.items.map((it) => {
                const cc = costCodeById.get(it.cost_code_id);
                const bl = it.budget_line_id ? budgetLineById.get(it.budget_line_id) : undefined;
                return (
                  <Tr key={it.id}>
                    <Td>{it.description}</Td>
                    <Td className="text-text-muted">{cc ? costCodeLabel(cc) : "—"}</Td>
                    <Td className="text-text-muted">{bl ? bl.description : it.budget_line_id ? "Bağlı" : "—"}</Td>
                    <Td className="text-right">
                      {it.quantity !== null && it.quantity !== undefined
                        ? `${it.quantity.toLocaleString("tr-TR")} ${it.unit}`.trim()
                        : "—"}
                    </Td>
                    <Td className="text-right">
                      {it.unit_price !== null && it.unit_price !== undefined ? formatMoney(it.unit_price, currency) : "—"}
                    </Td>
                    <Td className="text-right">{formatMoney(it.original_amount, currency)}</Td>
                  </Tr>
                );
              })}
              <Tr>
                <Td colSpan={5} className="text-right font-semibold">
                  Toplam
                </Td>
                <Td className="text-right font-semibold">{formatMoney(sc.original_amount, currency)}</Td>
              </Tr>
            </tbody>
          </Table>
        )}
      </Section>

      <ClaimsPanel
        project={project}
        subcontract={sc}
        sovItems={detail.items}
        value={value}
        claims={claims}
        payments={payments}
        changeOrders={changeOrders ?? []}
        costCodes={costCodes}
        perms={perms}
        locked={locked}
        focusClaimId={focusClaimId}
      />

      <ChangeOrdersPanel
        project={project}
        subcontract={sc}
        changeOrders={changeOrders}
        costCodes={costCodes}
        budgetLines={budgetLines}
        wbsNodes={wbsNodes}
        perms={perms}
        locked={locked}
        focusChangeOrderId={focusChangeOrderId}
      />

      {perms.canReadPayments && (
        <PaymentsPanel
          project={project}
          subcontract={sc}
          payments={payments}
          claims={claims}
          perms={perms}
          locked={locked}
        />
      )}

      {detail.commitments.length > 0 && (
        <Section title="Maliyet Kontrolü Taahhütleri">
          <p className="mb-3 text-xs text-text-muted">
            Aktifleştirme, değişiklik onayı ve fesih bu taahhütleri yeniden senkronize eder; tamamlama dokunmaz.
          </p>
          <Table>
            <thead>
              <tr>
                <Th>Maliyet Kodu</Th>
                <Th>Durum</Th>
                <Th className="text-right">Taahhüt</Th>
              </tr>
            </thead>
            <tbody>
              {detail.commitments.map((c) => {
                const cc = costCodeById.get(c.cost_code_id);
                const label = c.cost_code_code ? `${c.cost_code_code} — ${c.cost_code_name ?? ""}` : cc ? costCodeLabel(cc) : "—";
                return (
                  <Tr key={c.id}>
                    <Td>{label}</Td>
                    <Td>
                      <StatusPill registry={COMMITMENT_STATUS} status={c.status} />
                    </Td>
                    <Td className={`text-right ${c.status === "voided" ? "text-text-muted line-through" : ""}`}>
                      {formatMoney(c.committed_amount, c.currency || currency)}
                    </Td>
                  </Tr>
                );
              })}
            </tbody>
          </Table>
        </Section>
      )}

      {dialog}
      {reasonDialog}
    </div>
  );
}

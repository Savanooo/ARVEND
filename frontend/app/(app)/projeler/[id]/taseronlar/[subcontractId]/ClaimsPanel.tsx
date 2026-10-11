"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useRef, useState } from "react";

import { Section } from "@/components/ui/Accordion";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Textarea } from "@/components/ui/Textarea";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney, formatPercent, parseAmountTR } from "@/lib/format";
import {
  approvedChangeNetByGroup,
  buildClaimItems,
  claimActions,
  claimCapCheck,
  claimEntryAmounts,
  claimPreview,
  claimUnpaidRemainder,
  latestCertifiedCumulative,
  paidAgainstClaim,
  PROGRESS_CLAIM_STATUS,
  subcontractActions,
  type ClaimCapIssue,
  type ProgressClaim,
  type ProgressClaimItem,
  type Subcontract,
  type SubcontractChangeOrder,
  type SubcontractChangeOrderItem,
  type SubcontractItem,
  type SubcontractPayment,
  type SubcontractPerms,
  type SubcontractValue,
} from "@/lib/subcontracts";
import type { OrganizationCostCode, Project } from "@/lib/types";

import { costCodeLabel, Field, formatDay, formatTs, inputClass, StatusPill, useSubcontractAction } from "../shared";

// Taşeron hakedişi (Progress Claim) -- mobil progress_claim_detail/form
// ekranlarının karşılığı. Müşteri hakedişi DEĞİLDİR; sertifikalı hakediş
// "ödendi" demek DEĞİLDİR (gerçek ödeme Ödemeler bölümünde). Sertifikalı
// hakediş kilitlidir, düzeltme yeni bir hakedişle yapılır.

type ClaimDetail = { progress_claim: ProgressClaim; items: ProgressClaimItem[] };

function claimUrl(projectId: string, claimId: string) {
  return `/api/v1/projects/${projectId}/subcontract-progress-claims/${claimId}`;
}

export function ClaimsPanel({
  project,
  subcontract,
  sovItems,
  value,
  claims,
  payments,
  changeOrders,
  costCodes,
  perms,
  locked,
  focusClaimId,
}: {
  project: Project;
  subcontract: Subcontract;
  sovItems: SubcontractItem[];
  value: SubcontractValue;
  claims: ProgressClaim[] | null;
  payments: SubcontractPayment[] | null;
  changeOrders: SubcontractChangeOrder[];
  costCodes: OrganizationCostCode[] | null;
  perms: SubcontractPerms;
  locked: boolean;
  focusClaimId: string | null;
}) {
  const [form, setForm] = useState<null | { claim?: ProgressClaim; items?: ProgressClaimItem[] }>(null);
  const canAdd = subcontractActions(subcontract.status, perms, locked).addClaim;

  if (!perms.canReadClaims) return null;

  return (
    <Section title="Hakedişler" defaultOpen>
      {claims === null ? (
        <p className="text-text-muted">Hakedişler yüklenemedi.</p>
      ) : (
        <div className="flex flex-col gap-3">
          {claims.length === 0 && !form && <p className="text-text-muted">Henüz hakediş yok.</p>}
          {claims.map((c) => (
            <ClaimCard
              key={c.id}
              project={project}
              subcontract={subcontract}
              claim={c}
              payments={payments}
              perms={perms}
              locked={locked}
              focused={c.id === focusClaimId}
              onEdit={(items) => setForm({ claim: c, items })}
            />
          ))}
          {form ? (
            <ClaimForm
              key={form.claim?.id ?? "new"}
              project={project}
              subcontract={subcontract}
              sovItems={sovItems}
              value={value}
              claims={claims}
              changeOrders={changeOrders}
              costCodes={costCodes}
              initial={form.claim && form.items ? { claim: form.claim, items: form.items } : null}
              locked={locked}
              onClose={() => setForm(null)}
            />
          ) : (
            canAdd && (
              <div>
                <Button type="button" variant="secondary" onClick={() => setForm({})}>
                  + Hakediş Ekle
                </Button>
              </div>
            )
          )}
          {subcontract.status !== "active" && subcontract.status !== "draft" && (
            <p className="text-xs text-text-muted">Yeni hakediş yalnızca aktif sözleşmeye girilebilir.</p>
          )}
        </div>
      )}
    </Section>
  );
}

// ---------- Hakediş kartı ----------

function ClaimCard({
  project,
  subcontract,
  claim,
  payments,
  perms,
  locked,
  focused,
  onEdit,
}: {
  project: Project;
  subcontract: Subcontract;
  claim: ProgressClaim;
  payments: SubcontractPayment[] | null;
  perms: SubcontractPerms;
  locked: boolean;
  focused: boolean;
  onEdit: (items: ProgressClaimItem[]) => void;
}) {
  const currency = subcontract.currency;
  const { busy, error, setError, run } = useSubcontractAction(locked);
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const { askReason, dialog: reasonDialog } = useReasonDialog();
  const [expanded, setExpanded] = useState(focused);
  const [items, setItems] = useState<ProgressClaimItem[] | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  const actions = claimActions(claim.status, subcontract.status, perms, locked);
  const url = claimUrl(project.id, claim.id);

  useEffect(() => {
    if (focused) ref.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [focused]);

  useEffect(() => {
    if (!expanded || items) return;
    (async () => {
      try {
        const d = await apiClient<ClaimDetail>(url);
        setItems(d.items);
      } catch {
        setItems([]);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded]);

  // Kayıt değişince (router.refresh) kalemler yeniden okunsun.
  useEffect(() => {
    setItems(null);
  }, [claim.updated_at]);

  async function submit() {
    if (!(await confirm({ title: "Hakedişi Gönder", message: `${claim.claim_number} sertifikasyon için gönderilsin mi?`, confirmLabel: "Gönder" })))
      return;
    if (await run(() => apiClient(`${url}/submit`, { method: "POST" }))) toast.success(`${claim.claim_number} gönderildi.`);
  }
  async function cancel() {
    if (
      !(await confirm({
        title: "Hakedişi İptal Et",
        message: `${claim.claim_number} iptal edilsin mi? Bu işlem geri alınamaz.`,
        confirmLabel: "İptal Et",
        danger: true,
      }))
    )
      return;
    if (await run(() => apiClient(`${url}/cancel`, { method: "POST" }))) toast.success("Hakediş iptal edildi.");
  }
  async function certify() {
    if (
      !(await confirm({
        title: "Hakedişi Sertifikala",
        message: `${claim.claim_number} sertifikalansın mı? Sertifikalı hakediş kilitlenir; düzeltme yeni bir hakedişle yapılır. Sertifika ödeme değildir.`,
        confirmLabel: "Sertifikala",
      }))
    )
      return;
    if (await run(() => apiClient(`${url}/certify`, { method: "POST" }))) toast.success(`${claim.claim_number} sertifika edildi.`);
  }
  async function reject() {
    const reason = await askReason({
      title: "Hakedişi Reddet",
      message: `${claim.claim_number} reddedilecek.`,
      label: "Red gerekçesi",
      confirmLabel: "Reddet",
      danger: true,
      required: true,
    });
    if (reason === null) return;
    if (await run(() => apiClient(`${url}/reject`, { method: "POST", body: JSON.stringify({ reason }) })))
      toast.success("Hakediş reddedildi.");
  }
  async function edit() {
    setError(null);
    try {
      const d = items ?? (await apiClient<ClaimDetail>(url)).items;
      onEdit(d);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    }
  }

  // Ödeme durumu yalnızca sertifikalı hakedişte (ödeme yalnızca ona bağlanır)
  // ve ödeme okuma izniyle.
  const showPayment = claim.status === "certified" && payments !== null;
  const paid = showPayment ? paidAgainstClaim(payments!, claim.id) : 0;
  const unpaid = showPayment ? claimUnpaidRemainder(claim, payments!) : 0;
  const anyAction = actions.edit || actions.submit || actions.cancel || actions.approve || actions.reject;

  return (
    <div
      ref={ref}
      id={`hakedis-${claim.id}`}
      className={`rounded-md border p-3 ${focused ? "border-gold" : "border-border"}`}
    >
      <button
        type="button"
        className="flex w-full flex-wrap items-center justify-between gap-2 text-left"
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}
      >
        <div>
          <span className="font-medium">{claim.claim_number}</span>
          <span className="ml-2 text-text-muted">
            {claim.period_start ? `${formatDay(claim.period_start)} – ` : ""}
            {formatDay(claim.period_end)}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <span className="font-medium">{formatMoney(claim.net_payable, currency)}</span>
          <StatusPill registry={PROGRESS_CLAIM_STATUS} status={claim.status} />
        </div>
      </button>
      {expanded && (
        <div className="mt-3 flex flex-col gap-4 border-t border-border pt-3 text-sm">
          <div className="grid grid-cols-2 gap-4 md:grid-cols-3">
            <Field label="Brüt Hakediş" value={formatMoney(claim.gross_work_amount, currency)} />
            <Field
              label={`Teminat Kesintisi (${formatPercent(claim.retention_percent_snapshot)})`}
              value={<span className="text-danger">−{formatMoney(claim.retention_amount, currency)}</span>}
            />
            <Field
              label="Avans Mahsubu"
              value={claim.advance_recovery_amount ? <span className="text-danger">−{formatMoney(claim.advance_recovery_amount, currency)}</span> : "—"}
            />
            <Field
              label="Diğer Kesintiler"
              value={claim.other_deductions ? <span className="text-danger">−{formatMoney(claim.other_deductions, currency)}</span> : "—"}
            />
            <Field label="Net Hakediş" value={<span className="font-semibold">{formatMoney(claim.net_payable, currency)}</span>} />
            <Field label="Kümülatif Sertifika (önceki → güncel)" value={`${formatMoney(claim.previous_certified_amount, currency)} → ${formatMoney(claim.current_certified_amount, currency)}`} />
          </div>
          <p className="text-xs text-text-muted">
            Net hakediş bir yükümlülüktür; ödendiği anlamına gelmez.
            {claim.submitted_at && ` Gönderildi: ${formatTs(claim.submitted_at)}.`}
            {claim.certified_at && ` Sertifika: ${formatTs(claim.certified_at)}.`}
          </p>

          {showPayment && (
            <div className="grid grid-cols-2 gap-4 rounded-md border border-border p-3 md:grid-cols-3">
              <Field label="Net Hakediş" value={formatMoney(claim.net_payable, currency)} />
              <Field label="Bu Hakedişe Karşı Ödenen" value={<span className="text-success">{formatMoney(paid, currency)}</span>} />
              <Field
                label="Ödenmemiş Kalan"
                value={<span className={unpaid > 0.0009 ? "font-semibold text-danger" : "font-semibold text-success"}>{formatMoney(unpaid, currency)}</span>}
              />
            </div>
          )}

          {claim.status === "rejected" && claim.rejection_reason && (
            <p className="text-xs text-danger">Red gerekçesi: {claim.rejection_reason}</p>
          )}
          {claim.notes && <Field label="Notlar" value={<span className="whitespace-pre-line">{claim.notes}</span>} />}

          {items === null ? (
            <p className="text-xs text-text-muted">Kalemler yükleniyor…</p>
          ) : items.length === 0 ? (
            <p className="text-xs text-text-muted">Kalem yok.</p>
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Kalem</Th>
                  <Th className="text-right">Sözleşme (kalem)</Th>
                  <Th className="text-right">Önceki</Th>
                  <Th className="text-right">Bu Hakedişte</Th>
                  <Th className="text-right">Kümülatif</Th>
                  <Th className="text-right">İlerleme</Th>
                  <Th className="text-right">Kalan</Th>
                </tr>
              </thead>
              <tbody>
                {items.map((it) => (
                  <Tr key={it.id}>
                    <Td>
                      {it.item_description}
                      {it.item_unit ? <span className="text-text-muted"> ({it.item_unit})</span> : null}
                    </Td>
                    <Td className="text-right">{formatMoney(it.scheduled_value, currency)}</Td>
                    <Td className="text-right text-text-muted">{formatMoney(it.previous_progress_amount, currency)}</Td>
                    <Td className="text-right">{formatMoney(it.current_progress_amount, currency)}</Td>
                    <Td className="text-right">{formatMoney(it.cumulative_progress_amount, currency)}</Td>
                    <Td className="text-right">{formatPercent(Math.round(it.progress_percent * 10) / 10)}</Td>
                    <Td className="text-right">{formatMoney(it.remaining_amount, currency)}</Td>
                  </Tr>
                ))}
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
                <Button type="button" disabled={busy} onClick={certify}>
                  Sertifikala
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
          {claim.status === "submitted" && subcontract.status === "terminated" && perms.canCertifyClaims && !locked && (
            <p className="text-xs text-text-muted">
              Feshedilmiş sözleşmenin hakedişi sertifika edilemez (kalan taahhüt fesihte serbest bırakıldı); reddedin ya da iptal edin.
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

// ---------- Hakediş formu (oluştur / taslağı düzenle) ----------

type CapContext = { certified: Record<string, number>; changeNet: Record<string, number> } | "error" | null;

function ClaimForm({
  project,
  subcontract,
  sovItems,
  value,
  claims,
  changeOrders,
  costCodes,
  initial,
  locked,
  onClose,
}: {
  project: Project;
  subcontract: Subcontract;
  sovItems: SubcontractItem[];
  value: SubcontractValue;
  claims: ProgressClaim[];
  changeOrders: SubcontractChangeOrder[];
  costCodes: OrganizationCostCode[] | null;
  initial: { claim: ProgressClaim; items: ProgressClaimItem[] } | null;
  locked: boolean;
  onClose: () => void;
}) {
  const router = useRouter();
  const toast = useToast();
  const currency = subcontract.currency;
  const [form, setForm] = useState({
    period_start: initial?.claim.period_start ?? "",
    period_end: initial?.claim.period_end ?? "",
    // Yeni hakedişte sözleşmenin kesinti oranı önerilir (mobil gibi);
    // düzenlemede hakedişin kendi snapshot'ı.
    retention: String(initial ? initial.claim.retention_percent_snapshot : (subcontract.retention_percent ?? 0)),
    advance: initial?.claim.advance_recovery_amount ? String(initial.claim.advance_recovery_amount) : "",
    other: initial?.claim.other_deductions ? String(initial.claim.other_deductions) : "",
    notes: initial?.claim.notes ?? "",
  });
  const [entries, setEntries] = useState<Record<string, string>>(() =>
    Object.fromEntries((initial?.items ?? []).map((it) => [it.subcontract_item_id, String(it.current_progress_amount)]))
  );
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [capCtx, setCapCtx] = useState<CapContext>(null);

  // Sınır önizlemesi için: sertifikalı hakedişlerin kalemleri ("önceki") ve
  // onaylı değişiklik emirlerinin kalemleri (grup net eki). Yalnızca form
  // açılınca, bir kez çekilir; okunamazsa form sınırsız önizlemeyle çalışır.
  useEffect(() => {
    const certified = claims.filter((c) => c.status === "certified" && c.id !== initial?.claim.id);
    const approved = changeOrders.filter((co) => co.status === "approved");
    (async () => {
      try {
        const [claimDetails, coDetails] = await Promise.all([
          Promise.all(
            certified.map((c) =>
              apiClient<ClaimDetail>(claimUrl(project.id, c.id)).then((d) => ({ id: c.id, status: c.status, items: d.items }))
            )
          ),
          Promise.all(
            approved.map((co) =>
              apiClient<{ items: SubcontractChangeOrderItem[] }>(
                `/api/v1/projects/${project.id}/subcontract-change-orders/${co.id}`
              ).then((d) => ({ status: co.status, change_type: co.change_type, items: d.items }))
            )
          ),
        ]);
        setCapCtx({ certified: latestCertifiedCumulative(claimDetails), changeNet: approvedChangeNetByGroup(coDetails) });
      } catch {
        setCapCtx("error");
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const amounts = claimEntryAmounts(entries);
  const retentionPct = parseAmountTR(form.retention);
  const advance = form.advance.trim() === "" ? 0 : parseAmountTR(form.advance);
  const other = form.other.trim() === "" ? 0 : parseAmountTR(form.other);
  const preview = claimPreview({
    amounts: Object.values(amounts),
    retentionPercent: Number.isFinite(retentionPct) ? retentionPct : 0,
    advanceRecovery: Number.isFinite(advance) ? advance : 0,
    otherDeductions: Number.isFinite(other) ? other : 0,
  });
  const caps =
    capCtx && capCtx !== "error"
      ? claimCapCheck({
          sovItems,
          changeNetByGroup: capCtx.changeNet,
          certified: capCtx.certified,
          currentValue: value.current_value,
          entries: amounts,
        })
      : null;

  const costCodeById = new Map((costCodes ?? []).map((c) => [c.id, c]));
  const sovById = new Map(sovItems.map((it) => [it.id, it]));
  function issueText(i: ClaimCapIssue): string {
    if (i.kind === "item") {
      const it = sovById.get(i.key);
      return `${it?.description ?? "Kalem"}: kümülatif ${formatMoney(i.cumulative, currency)}, kalem sınırını (${formatMoney(i.limit, currency)}) aşıyor.`;
    }
    if (i.kind === "group") {
      const [ccId, blId] = i.key.split("|");
      const cc = costCodeById.get(ccId);
      const label = `${cc ? costCodeLabel(cc) : "Maliyet kodu"}${blId ? " (bütçe kalemi)" : ""}`;
      return `${label} grubu: kümülatif ${formatMoney(i.cumulative, currency)}, grup sınırını (${formatMoney(i.limit, currency)}) aşıyor.`;
    }
    return `Toplam kümülatif ${formatMoney(i.cumulative, currency)}, güncel sözleşme tutarını (${formatMoney(i.limit, currency)}) aşıyor.`;
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (locked) return;
    setError(null);
    if (!form.period_end) return setError("Dönem sonu tarihi gerekli.");
    if (form.period_start && form.period_start > form.period_end) return setError("Dönem başı, dönem sonundan sonra olamaz.");
    if (!Number.isFinite(retentionPct) || retentionPct < 0 || retentionPct > 100)
      return setError("Hakediş kesintisi oranı 0 ile 100 arasında olmalı.");
    if (!Number.isFinite(advance) || advance < 0) return setError("Avans mahsubu geçersiz.");
    if (!Number.isFinite(other) || other < 0) return setError("Diğer kesintiler geçersiz.");
    const built = buildClaimItems(
      sovItems.map((it) => it.id),
      entries
    );
    setRowErrors(built.errors);
    if (Object.keys(built.errors).length > 0) return setError("Kalemlerdeki hataları düzeltin.");
    if (built.items.length === 0) return setError("En az bir SOV kalemine bu dönemin tutarını girin.");

    setSaving(true);
    try {
      const body = JSON.stringify({
        period_start: form.period_start || null,
        period_end: form.period_end,
        retention_percent: retentionPct,
        advance_recovery_amount: advance,
        other_deductions: other,
        notes: form.notes.trim(),
        items: built.items,
      });
      if (initial) {
        await apiClient(claimUrl(project.id, initial.claim.id), { method: "PUT", body });
        toast.success("Hakediş güncellendi.");
      } else {
        await apiClient(`/api/v1/projects/${project.id}/subcontracts/${subcontract.id}/progress-claims`, {
          method: "POST",
          body,
        });
        toast.success("Hakediş oluşturuldu (taslak).");
      }
      router.refresh();
      onClose();
    } catch (err) {
      // Sınır aşımı (409) dahil sunucu mesajı olduğu gibi gösterilir.
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4 rounded-md border border-gold/60 p-3">
      <p className="text-sm font-semibold">{initial ? `${initial.claim.claim_number} — Düzenle` : "Yeni Hakediş"}</p>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <DateInput
          label="Dönem Başı (opsiyonel)"
          value={form.period_start}
          onChange={(e) => setForm({ ...form, period_start: e.target.value })}
        />
        <DateInput label="Dönem Sonu" value={form.period_end} onChange={(e) => setForm({ ...form, period_end: e.target.value })} />
      </div>

      <div className="flex flex-col gap-2">
        <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">
          Kalemler — SOV kalemi başına bu dönemin ilerleme tutarı
        </span>
        <Table>
          <thead>
            <tr>
              <Th>Kalem</Th>
              <Th className="text-right">Sözleşme (kalem)</Th>
              {caps && <Th className="text-right">Sınır</Th>}
              {caps && <Th className="text-right">Önceki (sertifikalı)</Th>}
              <Th className="text-right">Bu Dönem</Th>
              {caps && <Th className="text-right">Kalan</Th>}
            </tr>
          </thead>
          <tbody>
            {sovItems.map((it) => {
              const row = caps?.rows[it.id];
              const fillable = row ? Math.max(0, row.cap - row.previous) : 0;
              return (
                <Tr key={it.id}>
                  <Td>
                    {it.description}
                    {rowErrors[it.id] && <p className="text-xs text-danger">{rowErrors[it.id]}</p>}
                  </Td>
                  <Td className="text-right text-text-muted">{formatMoney(it.original_amount, currency)}</Td>
                  {caps && (
                    <Td className="text-right text-text-muted">{row ? formatMoney(row.cap, currency) : "—"}</Td>
                  )}
                  {caps && (
                    <Td className="text-right text-text-muted">{row ? formatMoney(row.previous, currency) : "—"}</Td>
                  )}
                  <Td className="text-right">
                    <div className="flex items-center justify-end gap-2">
                      {row && fillable > 0 && (
                        <button
                          type="button"
                          className="text-xs text-text-muted hover:text-gold"
                          title="Kalan sınırın tamamını yaz"
                          onClick={() => setEntries({ ...entries, [it.id]: String(Math.round(fillable * 100) / 100) })}
                        >
                          Kalanı yaz
                        </button>
                      )}
                      <input
                        className={`${inputClass} w-36 text-right`}
                        inputMode="decimal"
                        placeholder="—"
                        aria-label={`${it.description} bu dönem tutarı`}
                        value={entries[it.id] ?? ""}
                        onChange={(e) => setEntries({ ...entries, [it.id]: e.target.value })}
                      />
                    </div>
                  </Td>
                  {caps && (
                    <Td className={`text-right ${row?.over ? "font-semibold text-danger" : "text-text-muted"}`}>
                      {row ? formatMoney(row.remaining, currency) : "—"}
                    </Td>
                  )}
                </Tr>
              );
            })}
          </tbody>
        </Table>
        <p className="text-xs text-text-muted">
          Boş bırakılan kalem hakedişe girmez. Önceki tutar en son sertifikalı hakedişten otomatik alınır.
          {capCtx === null && " Sınırlar yükleniyor…"}
          {capCtx === "error" && " Sınır önizlemesi yüklenemedi; sınırları kayıtta sunucu denetler."}
        </p>
      </div>

      {caps && caps.issues.length > 0 && (
        <div className="rounded-md border border-danger/40 bg-danger-soft p-3 text-xs text-danger">
          <p className="font-semibold">Bu tutarlarla hakediş sınırı aşılıyor; sunucu kaydı reddedecek:</p>
          <ul className="mt-1 list-disc pl-5">
            {caps.issues.map((i) => (
              <li key={`${i.kind}-${i.key}`}>{issueText(i)}</li>
            ))}
          </ul>
          <p className="mt-1">Onaylı ek iş (değişiklik emri) sınırı yükseltir; eksiltme düşürür.</p>
        </div>
      )}

      <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
        <Input
          label="Hakediş Kesintisi %"
          inputMode="decimal"
          value={form.retention}
          onChange={(e) => setForm({ ...form, retention: e.target.value })}
        />
        <Input
          label={`Avans Mahsubu (${currency}, opsiyonel)`}
          inputMode="decimal"
          value={form.advance}
          onChange={(e) => setForm({ ...form, advance: e.target.value })}
        />
        <Input
          label={`Diğer Kesintiler (${currency}, opsiyonel)`}
          inputMode="decimal"
          value={form.other}
          onChange={(e) => setForm({ ...form, other: e.target.value })}
        />
      </div>

      <div className="grid grid-cols-2 gap-3 rounded-md border border-border p-3 text-sm md:grid-cols-5">
        <Field label="Brüt" value={formatMoney(preview.gross, currency)} />
        <Field label="Teminat Kesintisi" value={`−${formatMoney(preview.retention, currency)}`} />
        <Field label="Avans Mahsubu" value={`−${formatMoney(preview.advance, currency)}`} />
        <Field label="Diğer" value={`−${formatMoney(preview.other, currency)}`} />
        <Field label="Net Hakediş (önizleme)" value={<span className="font-semibold">{formatMoney(preview.net, currency)}</span>} />
      </div>

      <Textarea label="Notlar (opsiyonel)" value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />

      {error && <p className="text-sm text-danger">{error}</p>}
      <div className="flex gap-2">
        <Button type="submit" loading={saving}>
          {initial ? "Kaydet" : "Hakediş Oluştur"}
        </Button>
        <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>
          Vazgeç
        </Button>
      </div>
      <p className="text-xs text-text-muted">
        Kayıt taslak olarak oluşur; sertifikasyon için ayrıca &quot;Gönder&quot; gerekir. Kesin tutarları sunucu hesaplar.
      </p>
    </form>
  );
}

"use client";

import { FormEvent, useState } from "react";

import { Section } from "@/components/ui/Accordion";
import { Button } from "@/components/ui/Button";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { Select } from "@/components/ui/Select";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { useToast } from "@/components/ui/Toast";
import { apiClient } from "@/lib/api";
import { formatMoney, istanbulDate, parseAmountTR } from "@/lib/format";
import {
  canVoidPayment,
  claimUnpaidRemainder,
  paidAgainstClaim,
  payableClaims,
  subcontractActions,
  type ProgressClaim,
  type Subcontract,
  type SubcontractPayment,
  type SubcontractPerms,
} from "@/lib/subcontracts";
import type { Project } from "@/lib/types";

import { formatDay, useSubcontractAction } from "../shared";

// Taşeron ödemeleri (migration 0039) -- GERÇEK nakit çıkışı; hakediş
// sertifikasyonu DEĞİLDİR (mobil subcontract_payment_form_sheet karşılığı).
// Okuma/yazma subcontract_payments.read/.manage ile, sözleşme izinlerinden
// AYRI. Ödeme yalnızca aktif/tamamlanmış/feshedilmiş sözleşmeye girilir;
// toplam güncel sözleşme tutarını, hakedişe bağlı ödeme o hakedişin net
// tutarını aşamaz -- ikisini de sunucu denetler (409 mesajı olduğu gibi).
// Legacy Finans > "Taşeron Ödemeleri" defterinden AYRIDIR.

// Anahtar form ÖRNEĞİ başına bir kez üretilir, tekrar denemede AYNI kalır;
// yalnızca kayıt kesinleşince yenilenir (FinanceSections ile aynı ilke).
function newIdempotencyKey() {
  return crypto.randomUUID();
}

export function PaymentsPanel({
  project,
  subcontract,
  payments,
  claims,
  perms,
  locked,
}: {
  project: Project;
  subcontract: Subcontract;
  payments: SubcontractPayment[] | null;
  claims: ProgressClaim[] | null;
  perms: SubcontractPerms;
  locked: boolean;
}) {
  const currency = subcontract.currency;
  const { busy, error, run } = useSubcontractAction(locked);
  const toast = useToast();
  const { askReason, dialog } = useReasonDialog();
  const canAdd = subcontractActions(subcontract.status, perms, locked).addPayment;
  const [open, setOpen] = useState(false);
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);
  const [form, setForm] = useState({
    amount: "",
    paid_date: istanbulDate(new Date()),
    progress_claim_id: "",
    payment_method: "",
    reference_no: "",
    description: "",
  });
  const [formError, setFormError] = useState<string | null>(null);

  const claimById = new Map((claims ?? []).map((c) => [c.id, c]));
  // Hakediş seçici yalnızca hakediş okuma izni olana ve sertifikalı
  // hakediş varsa (mobil gibi); yoksa ödeme bağlantısız kaydedilir.
  const selectable = claims ? payableClaims(claims) : [];
  const selectedClaim = form.progress_claim_id ? claimById.get(form.progress_claim_id) : undefined;

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (locked) return;
    setFormError(null);
    const amount = parseAmountTR(form.amount);
    if (!Number.isFinite(amount) || amount <= 0) return setFormError("Geçerli bir tutar girin.");
    if (!form.paid_date) return setFormError("Ödeme tarihi gerekli.");
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/subcontracts/${subcontract.id}/payments`, {
        method: "POST",
        body: JSON.stringify({
          amount,
          currency,
          paid_date: form.paid_date,
          progress_claim_id: form.progress_claim_id,
          payment_method: form.payment_method.trim(),
          reference_no: form.reference_no.trim(),
          description: form.description.trim(),
          idempotency_key: idempotencyKey,
        }),
      })
    );
    if (ok) {
      setIdempotencyKey(newIdempotencyKey());
      setForm({ ...form, amount: "", progress_claim_id: "", reference_no: "", description: "" });
      setOpen(false);
      toast.success("Ödeme kaydedildi.");
    }
  }

  async function voidPayment(p: SubcontractPayment) {
    const reason = await askReason({
      title: "Taşeron Ödemesini İptal Et",
      message: `${formatMoney(p.amount, p.currency || currency)} tutarındaki ödeme iptal edilecek; kayıt silinmez, İPTAL olarak işaretlenir ve kalan ödenecek tutar geri artar.`,
      label: "İptal nedeni",
      confirmLabel: "İptal Et",
      danger: true,
    });
    if (reason === null) return;
    if (
      await run(() =>
        apiClient(`/api/v1/projects/${project.id}/subcontract-payments/${p.id}/void`, {
          method: "POST",
          body: JSON.stringify({ reason }),
        })
      )
    )
      toast.success("Ödeme iptal edildi.");
  }

  return (
    <Section title="Ödemeler" defaultOpen>
      <div className="flex flex-col gap-3">
        {dialog}
        <p className="text-xs text-text-muted">
          Gerçek bir nakit çıkışını kaydeder — hakediş sertifikasyonundan ayrıdır. Toplamlar Ticari Özet&apos;tedir.
        </p>

        {payments === null ? (
          <p className="text-text-muted">Ödemeler yüklenemedi.</p>
        ) : payments.length === 0 ? (
          <p className="text-text-muted">Henüz ödeme kaydı yok.</p>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Tarih</Th>
                <Th>Hakediş</Th>
                <Th>Yöntem</Th>
                <Th>Referans</Th>
                <Th>Açıklama</Th>
                <Th className="text-right">Tutar</Th>
                <Th className="w-16" />
              </tr>
            </thead>
            <tbody>
              {payments.map((p) => {
                const claim = p.progress_claim_id ? claimById.get(p.progress_claim_id) : undefined;
                return (
                  <Tr key={p.id} className={p.voided_at ? "opacity-50" : ""}>
                    <Td className="whitespace-nowrap text-text-muted">{formatDay(p.paid_date)}</Td>
                    <Td className="text-text-muted">
                      {claim ? claim.claim_number : p.progress_claim_id ? "Bağlı" : "Bağlı değil"}
                    </Td>
                    <Td className="text-text-muted">{p.payment_method || "—"}</Td>
                    <Td className="text-text-muted">{p.reference_no || "—"}</Td>
                    <Td>
                      {p.description || "—"}
                      {p.voided_at && (
                        <span className="ml-2 text-xs text-danger">İPTAL{p.void_reason && ` · ${p.void_reason}`}</span>
                      )}
                    </Td>
                    <Td className={`text-right ${p.voided_at ? "line-through" : "font-medium text-success"}`}>
                      {formatMoney(p.amount, p.currency || currency)}
                    </Td>
                    <Td className="text-right">
                      {canVoidPayment(p, perms, locked) && (
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => voidPayment(p)}
                          className="text-xs text-danger hover:underline disabled:opacity-40"
                        >
                          İptal Et
                        </button>
                      )}
                    </Td>
                  </Tr>
                );
              })}
            </tbody>
          </Table>
        )}

        {open ? (
          <form onSubmit={submit} className="flex flex-col gap-3 rounded-md border border-gold/60 p-3">
            <p className="text-sm font-semibold">Taşeron Ödemesi Kaydet</p>
            <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
              <Input
                label={`Ödenen Tutar (${currency})`}
                inputMode="decimal"
                value={form.amount}
                onChange={(e) => setForm({ ...form, amount: e.target.value })}
              />
              <DateInput
                label="Ödeme Tarihi"
                value={form.paid_date}
                onChange={(e) => setForm({ ...form, paid_date: e.target.value })}
              />
              {selectable.length > 0 && (
                <Select
                  label="Hakediş (opsiyonel)"
                  value={form.progress_claim_id}
                  onChange={(e) => setForm({ ...form, progress_claim_id: e.target.value })}
                >
                  <option value="">Bağlı değil (avans vb.)</option>
                  {selectable.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.claim_number} · net {formatMoney(c.net_payable, currency)}
                    </option>
                  ))}
                </Select>
              )}
            </div>
            {selectable.length > 0 && (
              <p className="text-xs text-text-muted">
                {selectedClaim
                  ? `Net hakediş ${formatMoney(selectedClaim.net_payable, currency)}` +
                    (payments
                      ? ` · ödenen ${formatMoney(paidAgainstClaim(payments, selectedClaim.id), currency)} · kalan ${formatMoney(
                          claimUnpaidRemainder(selectedClaim, payments),
                          currency
                        )}`
                      : "")
                  : "Bu ödeme bir hakedişin karşılığıysa seçin."}
              </p>
            )}
            <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
              <Input
                label="Ödeme Yöntemi (opsiyonel)"
                value={form.payment_method}
                onChange={(e) => setForm({ ...form, payment_method: e.target.value })}
              />
              <Input
                label="Referans No (opsiyonel)"
                value={form.reference_no}
                onChange={(e) => setForm({ ...form, reference_no: e.target.value })}
              />
              <Input
                label="Açıklama (opsiyonel)"
                value={form.description}
                onChange={(e) => setForm({ ...form, description: e.target.value })}
              />
            </div>
            {(formError || error) && <p className="text-sm text-danger">{formError ?? error}</p>}
            <div className="flex gap-2">
              <Button type="submit" loading={busy}>
                Kaydet
              </Button>
              <Button
                type="button"
                variant="ghost"
                disabled={busy}
                onClick={() => {
                  setOpen(false);
                  setFormError(null);
                }}
              >
                Vazgeç
              </Button>
            </div>
          </form>
        ) : (
          <>
            {error && <p className="text-xs text-danger">{error}</p>}
            {canAdd && (
              <div>
                <Button type="button" variant="secondary" onClick={() => setOpen(true)}>
                  + Ödeme Ekle
                </Button>
              </div>
            )}
          </>
        )}
        {!locked && perms.canManagePayments && (subcontract.status === "draft" || subcontract.status === "cancelled") && (
          <p className="text-xs text-text-muted">
            Ödeme yalnızca aktif, tamamlanmış ya da feshedilmiş sözleşmeye kaydedilebilir.
          </p>
        )}
      </div>
    </Section>
  );
}

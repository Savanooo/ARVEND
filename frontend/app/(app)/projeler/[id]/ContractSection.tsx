"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { useReasonDialog } from "@/components/ui/ReasonDialog";
import { DateInput } from "@/components/ui/DateInput";
import { EmptyState } from "@/components/ui/EmptyState";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Textarea } from "@/components/ui/Textarea";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { formatSignedMoney } from "@/lib/format";
import { CHANGE_ORDER_STATUS, CONTRACT_STATUS } from "@/lib/status";
import type { ChangeOrder, Project, ProjectContract } from "@/lib/types";

// Sprint 3 — Proje Sözleşmesi (Contract). Gelir (revenue) tarafı — Maliyet
// Kontrolü (Sprint 2, maliyet tarafı) İLE KARIŞTIRILMAMALI. Durum makinesi:
// draft -> active -> completed; draft -> cancelled; active -> terminated
// (bkz. docs/contracts.md). Backend HER geçişi bağımsız olarak reddeder --
// bu dosyadaki buton görünürlüğü yalnızca UX'tir, gerçek sınır değildir.

function useContractAction(locked: boolean) {
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

function formatDate(d: string | null | undefined) {
  return d ? new Date(d).toLocaleDateString("tr-TR") : "—";
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs uppercase tracking-widest text-text-muted">{label}</span>
      <span>{value}</span>
    </div>
  );
}

export function ContractSection({
  project,
  contract,
  changeOrders,
  locked,
}: {
  project: Project;
  contract: ProjectContract | null;
  changeOrders: ChangeOrder[];
  locked: boolean;
}) {
  const { busy, error, run } = useContractAction(locked);
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const { askReason, dialog: reasonDialog } = useReasonDialog();

  const [form, setForm] = useState({
    scope: contract?.scope ?? "",
    payment_terms: contract?.payment_terms ?? "",
    retention_terms: contract?.retention_terms ?? "",
    advance_terms: contract?.advance_terms ?? "",
    effective_date: contract?.effective_date ?? "",
    planned_completion_date: contract?.planned_completion_date ?? "",
  });
  const [notes, setNotes] = useState(contract?.internal_notes ?? "");

  async function createContract() {
    await run(() => apiClient(`/api/v1/projects/${project.id}/contract`, { method: "POST" }));
  }

  if (!contract) {
    return (
      <EmptyState
        title="Bu proje için henüz bir sözleşme yok"
        description="Sözleşme oluşturduktan sonra kapsam/ödeme koşullarını doldurabilir ve aktifleştirebilirsiniz."
        action={
          !locked && (
            <Button onClick={createContract} disabled={busy}>
              Sözleşme Oluştur
            </Button>
          )
        }
      />
    );
  }

  const isDraft = contract.status === "draft";
  const isActive = contract.status === "active";
  const notesEditable = isDraft || isActive;

  async function saveDraftFields(e: FormEvent) {
    e.preventDefault();
    await run(() =>
      apiClient(`/api/v1/projects/${project.id}/contract`, {
        method: "PUT",
        body: JSON.stringify({
          scope: form.scope,
          payment_terms: form.payment_terms,
          retention_terms: form.retention_terms,
          advance_terms: form.advance_terms,
          effective_date: form.effective_date || null,
          planned_completion_date: form.planned_completion_date || null,
        }),
      })
    );
  }

  async function saveNotes(e: FormEvent) {
    e.preventDefault();
    await run(() =>
      apiClient(`/api/v1/projects/${project.id}/contract/notes`, {
        method: "PUT",
        body: JSON.stringify({ internal_notes: notes }),
      })
    );
  }

  async function activate() {
    const ok = await confirm({
      title: "Sözleşmeyi Aktifleştir",
      message:
        "Aktivasyon, ticari şartları (kapsam, ödeme/hakediş/avans koşulları, tarihler) KALICI olarak kilitler — bundan sonraki değişiklikler resmi bir Ek İş gerektirir. Bu işlem GERİ ALINAMAZ.",
      confirmLabel: "Aktifleştir",
      danger: true,
    });
    if (!ok) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/contract/activate`, { method: "POST" }));
    if (done) toast.success("Sözleşme aktifleştirildi.");
  }

  async function complete() {
    const ok = await confirm({
      title: "Sözleşmeyi Tamamla",
      message: "Sözleşme tamamlandı olarak işaretlenecek. Bu işlem GERİ ALINAMAZ.",
      confirmLabel: "Tamamla",
    });
    if (!ok) return;
    const done = await run(() => apiClient(`/api/v1/projects/${project.id}/contract/complete`, { method: "POST" }));
    if (done) toast.success("Sözleşme tamamlandı.");
  }

  async function cancelContract() {
    const reason = await askReason({
      title: "Sözleşmeyi İptal Et",
      message: "Bu taslak sözleşme iptal edilecek. Bu işlem GERİ ALINAMAZ.",
      label: "İptal nedeni",
      confirmLabel: "İptal Et",
      danger: true,
      required: true,
    });
    if (reason === null) return;
    const done = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/contract/cancel`, { method: "POST", body: JSON.stringify({ reason }) })
    );
    if (done) toast.success("Sözleşme iptal edildi.");
  }

  async function terminateContract() {
    const reason = await askReason({
      title: "Sözleşmeyi Feshet",
      message: "Aktif sözleşme erken feshedilecek. Bu işlem GERİ ALINAMAZ.",
      label: "Fesih nedeni",
      confirmLabel: "Feshet",
      danger: true,
      required: true,
    });
    if (reason === null) return;
    const done = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/contract/terminate`, { method: "POST", body: JSON.stringify({ reason }) })
    );
    if (done) toast.success("Sözleşme feshedildi.");
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border bg-surface p-3">
        <div className="flex items-center gap-3 text-sm">
          <StatusBadge status={contract.status} registry={CONTRACT_STATUS} />
          <span className="text-text-muted">
            {isDraft && "Taslak — şartlar serbestçe düzenlenebilir."}
            {isActive && "Aktif — ticari şartlar kilitli, değişiklikler Ek İş ile yapılır."}
            {contract.status === "completed" && "Tamamlandı."}
            {contract.status === "cancelled" && `İptal edildi${contract.cancel_reason ? ` — ${contract.cancel_reason}` : ""}.`}
            {contract.status === "terminated" &&
              `Feshedildi${contract.termination_reason ? ` — ${contract.termination_reason}` : ""}.`}
          </span>
        </div>
        {!locked && (
          <div className="flex gap-2">
            {isDraft && (
              <>
                <Button type="button" disabled={busy} onClick={activate}>
                  Aktifleştir
                </Button>
                <Button type="button" variant="danger" disabled={busy} onClick={cancelContract}>
                  İptal Et
                </Button>
              </>
            )}
            {isActive && (
              <>
                <Button type="button" disabled={busy} onClick={complete}>
                  Tamamla
                </Button>
                <Button type="button" variant="danger" disabled={busy} onClick={terminateContract}>
                  Feshet
                </Button>
              </>
            )}
          </div>
        )}
      </div>

      {isDraft ? (
        <form onSubmit={saveDraftFields} className="flex flex-col gap-3 rounded-md border border-border p-3">
          <Textarea
            label="Kapsam"
            placeholder="Sözleşme kapsamı"
            value={form.scope}
            onChange={(e) => setForm({ ...form, scope: e.target.value })}
          />
          <Textarea
            label="Ödeme Koşulları"
            value={form.payment_terms}
            onChange={(e) => setForm({ ...form, payment_terms: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Textarea
              label="Hakediş Koşulları"
              value={form.retention_terms}
              onChange={(e) => setForm({ ...form, retention_terms: e.target.value })}
            />
            <Textarea
              label="Avans Koşulları"
              value={form.advance_terms}
              onChange={(e) => setForm({ ...form, advance_terms: e.target.value })}
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <DateInput
              label="Yürürlük Tarihi"
              value={form.effective_date ?? ""}
              onChange={(e) => setForm({ ...form, effective_date: e.target.value })}
            />
            <DateInput
              label="Planlanan Bitiş Tarihi"
              value={form.planned_completion_date ?? ""}
              onChange={(e) => setForm({ ...form, planned_completion_date: e.target.value })}
            />
          </div>
          <div>
            <Button type="submit" loading={busy}>
              Kaydet
            </Button>
          </div>
        </form>
      ) : (
        <div className="flex flex-col gap-3 rounded-md border border-border p-3 text-sm">
          <p className="text-xs text-text-muted">
            Aktivasyon sonrası ticari şartlar kilitlidir — değişiklik için resmi bir Ek İş gereklidir.
          </p>
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <Field label="Yürürlük Tarihi" value={formatDate(contract.effective_date)} />
            <Field label="Planlanan Bitiş" value={formatDate(contract.planned_completion_date)} />
          </div>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            <Field label="Kapsam" value={contract.scope || "—"} />
            <Field label="Ödeme Koşulları" value={contract.payment_terms || "—"} />
            <Field label="Hakediş Koşulları" value={contract.retention_terms || "—"} />
            <Field label="Avans Koşulları" value={contract.advance_terms || "—"} />
          </div>
        </div>
      )}

      <form onSubmit={saveNotes} className="flex flex-col gap-2 rounded-md border border-border p-3">
        <Textarea
          label="Dahili Not (yalnızca ekip görür)"
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          disabled={!notesEditable}
        />
        {notesEditable && (
          <div>
            <Button type="submit" variant="secondary" loading={busy} disabled={locked}>
              Notu Kaydet
            </Button>
          </div>
        )}
      </form>

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex flex-col gap-2">
        <span className="text-xs uppercase tracking-widest text-text-muted">Bu Sözleşmeyi Değiştiren Ek İşler</span>
        {changeOrders.length === 0 ? (
          <p className="text-sm text-text-muted">Henüz ek iş/değişiklik emri yok.</p>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>No</Th>
                <Th>Başlık</Th>
                <Th>Durum</Th>
                <Th className="text-right">Tutar</Th>
              </tr>
            </thead>
            <tbody>
              {changeOrders.map((co) => (
                <Tr key={co.id}>
                  <Td className="font-medium">{co.change_order_no}</Td>
                  <Td>{co.title}</Td>
                  <Td>
                    <StatusBadge status={co.status} registry={CHANGE_ORDER_STATUS} />
                  </Td>
                  <Td className={`text-right ${co.change_type === "addition" ? "text-success" : "text-danger"}`}>
                    {formatSignedMoney(co.change_type === "deduction" ? -co.grand_total : co.grand_total, co.currency)}
                  </Td>
                </Tr>
              ))}
            </tbody>
          </Table>
        )}
      </div>

      {dialog}
      {reasonDialog}
    </div>
  );
}

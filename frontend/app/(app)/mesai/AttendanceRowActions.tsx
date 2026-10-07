"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { initialTimes, resolveWorkHours, statusHasHours } from "@/lib/attendance";
import type { AttendanceLog, AttendanceStatus } from "@/lib/types";

import { AttendanceTimeFields } from "./AttendanceTimeFields";

const STATUSES: AttendanceStatus[] = ["geldi", "yarım gün", "gelmedi", "izinli"];

const selectClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold";

export function AttendanceRowActions({ log }: { log: AttendanceLog }) {
  const router = useRouter();
  const toast = useToast();
  const [status, setStatus] = useState<AttendanceStatus>(log.status);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [editing, setEditing] = useState(false);

  async function handleStatusChange(next: AttendanceStatus) {
    const prev = status;
    setStatus(next);
    setSaving(true);
    try {
      await apiClient(`/api/v1/attendance/${log.id}`, {
        method: "PUT",
        body: JSON.stringify({
          check_in: log.check_in,
          check_out: log.check_out,
          work_hours: log.work_hours,
          status: next,
          note: log.note,
        }),
      });
      router.refresh();
    } catch (err) {
      setStatus(prev);
      toast.error(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete() {
    if (!confirm("Bu mesai kaydı silinsin mi?")) return;
    setDeleting(true);
    try {
      await apiClient(`/api/v1/attendance/${log.id}`, { method: "DELETE" });
      router.refresh();
    } catch (err) {
      toast.error(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setDeleting(false);
    }
  }

  return (
    <div className="flex items-center justify-end gap-2">
      <select
        value={status}
        disabled={saving}
        onChange={(e) => handleStatusChange(e.target.value as AttendanceStatus)}
        className="rounded-md border border-border bg-surface px-2 py-1 text-xs text-text outline-none focus:border-gold disabled:opacity-50"
      >
        {STATUSES.map((s) => (
          <option key={s} value={s}>
            {s}
          </option>
        ))}
      </select>
      <Button variant="secondary" disabled={saving} onClick={() => setEditing(true)} className="px-2 py-1 text-xs">
        Düzenle
      </Button>
      <Button variant="danger" disabled={deleting} onClick={handleDelete} className="px-2 py-1 text-xs">
        {deleting ? "…" : "Sil"}
      </Button>
      {editing && (
        <EditAttendanceModal
          log={{ ...log, status }}
          onClose={() => setEditing(false)}
          onSaved={(saved) => {
            setStatus(saved);
            setEditing(false);
            toast.success("Mesai kaydı güncellendi.");
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

// Giriş/çıkış/saat/durum/not düzenleme (PUT /attendance/{id}; tarih ve
// personel değişmez -- yanlış gün/kişi için kayıt silinip yeniden girilir).
function EditAttendanceModal({
  log,
  onClose,
  onSaved,
}: {
  log: AttendanceLog;
  onClose: () => void;
  onSaved: (status: AttendanceStatus) => void;
}) {
  const [status, setStatus] = useState<AttendanceStatus>(log.status);
  const [times, setTimes] = useState(() => initialTimes(statusHasHours(log.status) ? log : undefined));
  const [note, setNote] = useState(log.note);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const hasHours = statusHasHours(status);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const workHours = hasHours ? resolveWorkHours(times) : 0;
    if (hasHours && !(workHours > 0 && workHours <= 24)) {
      setError("Çalışılan saat 0 ile 24 arasında olmalı; giriş-çıkış saatlerini ya da saati kontrol edin.");
      return;
    }
    setError(null);
    setLoading(true);
    try {
      await apiClient(`/api/v1/attendance/${log.id}`, {
        method: "PUT",
        body: JSON.stringify({
          check_in: hasHours ? times.check_in : "",
          check_out: hasHours ? times.check_out : "",
          work_hours: workHours,
          status,
          note,
        }),
      });
      onSaved(status);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <Modal
      open
      onClose={onClose}
      dismissible={!loading}
      title={`Mesai Kaydını Düzenle${log.employee_name ? ` — ${log.employee_name}` : ""}`}
      footer={
        <>
          <Button type="button" variant="ghost" onClick={onClose} disabled={loading}>
            Vazgeç
          </Button>
          <Button type="submit" form={`attendance-edit-${log.id}`} loading={loading}>
            Kaydet
          </Button>
        </>
      }
    >
      <form id={`attendance-edit-${log.id}`} onSubmit={handleSubmit} className="flex flex-wrap items-end gap-3">
        <p className="basis-full text-xs text-text-muted">Tarih: {log.date}</p>
        <div className="flex flex-col gap-1.5">
          <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">Durum</label>
          <select value={status} onChange={(e) => setStatus(e.target.value as AttendanceStatus)} className={selectClass}>
            {STATUSES.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </div>
        {hasHours && <AttendanceTimeFields value={times} onChange={setTimes} idPrefix={`edit_${log.id}`} />}
        <div className="basis-full">
          <Input label="Not" name={`edit_${log.id}_note`} value={note} onChange={(e) => setNote(e.target.value)} />
        </div>
        {error && <p className="basis-full text-xs text-danger">{error}</p>}
      </form>
    </Modal>
  );
}

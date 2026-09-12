"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { apiClient, ApiError } from "@/lib/api";
import type { AttendanceLog, AttendanceStatus } from "@/lib/types";

const STATUSES: AttendanceStatus[] = ["geldi", "yarım gün", "gelmedi", "izinli"];

export function AttendanceRowActions({ log }: { log: AttendanceLog }) {
  const router = useRouter();
  const [status, setStatus] = useState<AttendanceStatus>(log.status);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);

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
      alert(err instanceof ApiError ? err.message : "Bağlantı hatası");
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
      alert(err instanceof ApiError ? err.message : "Bağlantı hatası");
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
      <Button variant="danger" disabled={deleting} onClick={handleDelete} className="px-2 py-1 text-xs">
        {deleting ? "…" : "Sil"}
      </Button>
    </div>
  );
}

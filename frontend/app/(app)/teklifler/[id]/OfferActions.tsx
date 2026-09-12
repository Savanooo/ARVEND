"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { apiClient, ApiError } from "@/lib/api";
import type { Offer, OfferStatus } from "@/lib/types";

const STATUSES: OfferStatus[] = ["taslak", "gönderildi", "kabul edildi", "reddedildi"];

export function OfferActions({ offer }: { offer: Offer }) {
  const router = useRouter();
  const [status, setStatus] = useState<OfferStatus>(offer.status);
  const [savingStatus, setSavingStatus] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function handleStatusChange(next: OfferStatus) {
    setStatus(next);
    setSavingStatus(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/status`, {
        method: "PUT",
        body: JSON.stringify({ status: next }),
      });
      router.refresh();
    } catch (err) {
      setStatus(offer.status);
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingStatus(false);
    }
  }

  async function handleDelete() {
    if (!confirm(`${offer.offer_no} silinsin mi?`)) return;
    setDeleting(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/offers/${offer.id}`, { method: "DELETE" });
      router.push("/teklifler");
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setDeleting(false);
    }
  }

  return (
    <div className="flex items-center gap-3">
      {message && <span className="text-xs text-danger">{message}</span>}
      <select
        value={status}
        disabled={savingStatus}
        onChange={(e) => handleStatusChange(e.target.value as OfferStatus)}
        className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold disabled:opacity-50"
      >
        {STATUSES.map((s) => (
          <option key={s} value={s}>
            {s}
          </option>
        ))}
      </select>
      <Button variant="danger" disabled={deleting} onClick={handleDelete}>
        {deleting ? "Siliniyor…" : "Sil"}
      </Button>
    </div>
  );
}

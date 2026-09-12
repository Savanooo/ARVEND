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
  const [revising, setRevising] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const canRevise = offer.status === "gönderildi" || offer.status === "reddedildi";

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

  async function handleRevise() {
    if (!confirm("Bu teklif için yeni bir revizyon oluşturulsun mu? Yeni revizyon taslak olarak düzenlenebilir.")) return;
    setRevising(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/revise`, { method: "POST" });
      router.push(`/teklifler/${offer.id}/duzenle`);
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setRevising(false);
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
      {canRevise && (
        <Button variant="secondary" disabled={revising} onClick={handleRevise}>
          {revising ? "Oluşturuluyor…" : "Revize Et"}
        </Button>
      )}
      <Button variant="danger" disabled={deleting} onClick={handleDelete}>
        {deleting ? "Siliniyor…" : "Sil"}
      </Button>
    </div>
  );
}

"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { Select } from "@/components/ui/Select";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { OFFER_STATUS } from "@/lib/status";
import type { Offer, OfferStatus } from "@/lib/types";

const STATUSES: OfferStatus[] = ["taslak", "gönderildi", "kabul edildi", "reddedildi"];

// Seçilebilir durumlar, backend'in (OfferService.UpdateStatus) kurallarının
// aynısıdır: müşteriye gönderilmiş/karar verilmiş bir revizyon taslağa geri
// alınamaz (değişiklik "Revize Et" ile yapılır), kabul edilmiş teklifin
// durumu ise hiç değiştirilemez -- reddedilecek bir seçenek gösterilmez.
function selectableStatuses(current: OfferStatus): OfferStatus[] {
  if (current === "kabul edildi") return ["kabul edildi"];
  if (current === "taslak") return STATUSES;
  return STATUSES.filter((s) => s !== "taslak");
}

// Geri alınamayan geçişlerin onay metinleri. Gönderildi de buna dahil:
// gönderilen teklif bir daha taslağa dönemez.
const STATUS_CONFIRM: Partial<Record<OfferStatus, { title: string; message: string; danger?: boolean }>> = {
  gönderildi: {
    title: "Gönderildi Olarak İşaretle",
    message:
      "Teklif gönderildi olarak işaretlensin mi? Gönderilen teklif artık düzenlenemez ve taslağa geri alınamaz; değişiklik için \"Revize Et\" kullanılır.",
  },
  "kabul edildi": {
    title: "Kabul Edildi Olarak İşaretle",
    message:
      "Teklif kabul edildi olarak işaretlensin mi? Kabul edilen teklifin durumu bir daha değiştirilemez, revize edilemez ve silinemez.",
  },
  reddedildi: {
    title: "Reddedildi Olarak İşaretle",
    message:
      "Teklif reddedildi olarak işaretlensin mi? Müşteri paylaşım bağlantısı üzerinden artık karar veremez; yeni bir teklif için \"Revize Et\" kullanılır.",
    danger: true,
  },
};

export function OfferActions({ offer }: { offer: Offer }) {
  const router = useRouter();
  const toast = useToast();
  const { confirm, dialog } = useConfirmDialog();
  const [status, setStatus] = useState<OfferStatus>(offer.status);
  const [savingStatus, setSavingStatus] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [revising, setRevising] = useState(false);

  const canRevise = offer.status === "gönderildi" || offer.status === "reddedildi";
  const statusOptions = selectableStatuses(offer.status);

  async function handleStatusChange(next: OfferStatus) {
    if (next === offer.status) return;
    const confirmation = STATUS_CONFIRM[next];
    if (confirmation) {
      const ok = await confirm({ ...confirmation, confirmLabel: "Evet, işaretle" });
      if (!ok) {
        setStatus(offer.status);
        return;
      }
    }
    setStatus(next);
    setSavingStatus(true);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/status`, {
        method: "PUT",
        body: JSON.stringify({ status: next }),
      });
      router.refresh();
    } catch (err) {
      setStatus(offer.status);
      toast.error(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSavingStatus(false);
    }
  }

  async function handleRevise() {
    const ok = await confirm({
      title: "Yeni Revizyon Oluştur",
      message: "Bu teklif için yeni bir revizyon oluşturulsun mu? Yeni revizyon taslak olarak düzenlenebilir.",
    });
    if (!ok) return;
    setRevising(true);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/revise`, { method: "POST" });
      toast.success("Yeni revizyon oluşturuldu.");
      router.push(`/teklifler/${offer.id}/duzenle`);
      router.refresh();
    } catch (err) {
      toast.error(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setRevising(false);
    }
  }

  async function handleDelete() {
    const ok = await confirm({
      title: "Teklifi Sil",
      message: `${offer.offer_no} silinsin mi?`,
      danger: true,
    });
    if (!ok) return;
    setDeleting(true);
    try {
      await apiClient(`/api/v1/offers/${offer.id}`, { method: "DELETE" });
      toast.success(`${offer.offer_no} silindi.`);
      router.push("/teklifler");
      router.refresh();
    } catch (err) {
      toast.error(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setDeleting(false);
    }
  }

  return (
    <div className="flex items-center gap-3">
      <Select
        value={status}
        disabled={savingStatus || statusOptions.length < 2}
        onChange={(e) => handleStatusChange(e.target.value as OfferStatus)}
        aria-label="Teklif durumu"
        className="w-40"
      >
        {statusOptions.map((s) => (
          <option key={s} value={s}>
            {OFFER_STATUS[s].label}
          </option>
        ))}
      </Select>
      {canRevise && (
        <Button variant="secondary" disabled={revising} onClick={handleRevise}>
          {revising ? "Oluşturuluyor…" : "Revize Et"}
        </Button>
      )}
      <Button variant="danger" disabled={deleting} onClick={handleDelete}>
        {deleting ? "Siliniyor…" : "Sil"}
      </Button>
      {dialog}
    </div>
  );
}

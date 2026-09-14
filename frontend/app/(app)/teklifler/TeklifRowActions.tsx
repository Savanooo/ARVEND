"use client";

import { MoreVertical, Pencil, Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

import { DropdownMenu, DropdownMenuItem } from "@/components/ui/DropdownMenu";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import type { Offer } from "@/lib/types";

// Sil, teklif detay sayfasındaki OfferActions.tsx'in AYNI mevcut
// yeteneğidir (DELETE /api/v1/offers/{id}) -- burada yalnızca listeden
// de erişilebilir hale getiriliyor, yeni bir iş kuralı eklenmiyor.
export function TeklifRowActions({
  offer,
  confirm,
}: {
  offer: Offer;
  confirm: (options: { title?: string; message: string; danger?: boolean }) => Promise<boolean>;
}) {
  const router = useRouter();
  const toast = useToast();
  const [deleting, setDeleting] = useState(false);

  async function handleDelete() {
    const ok = await confirm({
      title: "Teklifi Sil",
      message: `${offer.offer_no} silinsin mi? Bu işlem geri alınamaz.`,
      danger: true,
    });
    if (!ok) return;
    setDeleting(true);
    try {
      await apiClient(`/api/v1/offers/${offer.id}`, { method: "DELETE" });
      toast.success(`${offer.offer_no} silindi.`);
      router.refresh();
    } catch (err) {
      toast.error(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setDeleting(false);
    }
  }

  return (
    <DropdownMenu trigger={<MoreVertical size={18} strokeWidth={1.75} />} triggerLabel="İşlemler">
      {offer.status === "taslak" && (
        <DropdownMenuItem href={`/teklifler/${offer.id}/duzenle`}>
          <Pencil size={15} strokeWidth={1.75} />
          Düzenle
        </DropdownMenuItem>
      )}
      <DropdownMenuItem disabled={deleting} onClick={handleDelete} className="text-danger hover:bg-danger-soft">
        <Trash2 size={15} strokeWidth={1.75} />
        {deleting ? "Siliniyor…" : "Sil"}
      </DropdownMenuItem>
    </DropdownMenu>
  );
}

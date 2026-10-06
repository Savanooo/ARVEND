"use client";

import { FileDown } from "lucide-react";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { useToast } from "@/components/ui/Toast";
import { fetchWithSession } from "@/lib/api";

// Sunucunun Content-Disposition'ındaki dosya adı (önce RFC 5987
// filename*, sonra düz filename). API farklı bir origin'de olduğunda
// tarayıcı bu başlığı ancak backend CORS'ta açıkça "expose" ederse
// gösterir -- okunamazsa null döner ve sunucunun AYNI biçimi (bkz. backend
// offerPDFFilename: "Teklif-<no>[-R<rev>].pdf") burada üretilir.
function filenameFromDisposition(header: string | null): string | null {
  if (!header) return null;
  const star = /filename\*\s*=\s*UTF-8''([^;]+)/i.exec(header);
  if (star) {
    try {
      return decodeURIComponent(star[1].trim());
    } catch {
      // bozuk kodlama: düz filename'e düş
    }
  }
  const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(header);
  return plain ? plain[1].trim() : null;
}

function fallbackFilename(offerNo: string, revisionNo: number): string {
  const folded = offerNo
    .replace(/ç/g, "c").replace(/Ç/g, "C").replace(/ğ/g, "g").replace(/Ğ/g, "G")
    .replace(/ı/g, "i").replace(/İ/g, "I").replace(/ö/g, "o").replace(/Ö/g, "O")
    .replace(/ş/g, "s").replace(/Ş/g, "S").replace(/ü/g, "u").replace(/Ü/g, "U");
  let no = folded.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "teklif";
  if (revisionNo > 0) no = `${no}-R${revisionNo}`;
  return `Teklif-${no}.pdf`;
}

// "PDF İndir": dosya, oturumu yenileyebilen fetch (fetchWithSession) ile
// blob olarak indirilir. Düz bir <a href> kullanılmaz -- 15 dakikalık
// access cookie'si dolduğunda tarayıcının doğrudan isteği 401 alıp
// indirilemezdi; fetchWithSession 401'de oturumu yenileyip tekrar dener.
export function DownloadPdfButton({
  offerId,
  offerNo,
  revisionNo,
}: {
  offerId: string;
  offerNo: string;
  revisionNo: number;
}) {
  const toast = useToast();
  const [loading, setLoading] = useState(false);

  async function handleDownload() {
    setLoading(true);
    try {
      const res = await fetchWithSession(`/api/v1/offers/${offerId}/pdf`);
      if (!res.ok) {
        let message = "PDF oluşturulamadı.";
        try {
          const body = (await res.json()) as { error?: string } | null;
          if (body?.error) message = body.error;
        } catch {
          // gövde JSON değil: genel mesaj
        }
        toast.error(message);
        return;
      }
      const blob = await res.blob();
      const filename =
        filenameFromDisposition(res.headers.get("Content-Disposition")) ?? fallbackFilename(offerNo, revisionNo);
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = filename;
      document.body.appendChild(link);
      link.click();
      link.remove();
      // Tarayıcı indirmeyi başlatana kadar URL geçerli kalmalı.
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    } catch {
      toast.error("Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Button variant="secondary" disabled={loading} onClick={handleDownload}>
      <FileDown size={16} strokeWidth={1.75} />
      {loading ? "Hazırlanıyor…" : "PDF İndir"}
    </Button>
  );
}

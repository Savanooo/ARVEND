"use client";

import { RefreshCw } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";

import { IconButton } from "@/components/ui/IconButton";
import { FOCUS_RING } from "@/components/ui/styles";
import { apiClient } from "@/lib/api";
import { COPY, DASHBOARD_PATH } from "@/lib/dashboard";

// "Güncellendi 09:41" + Yenile. Yenileme geçiş (transition) içinde çalışır,
// eski içerik yerinde kalır (iskelet yanıp sönmez), yalnızca ikon döner.
//
// Önce özet tarayıcıdan bir kez istenir: ulaşılamıyorsa router.refresh()
// ÇAĞRILMAZ -- çağrılsaydı sunucudaki DashboardBody hatayı "Özet
// yüklenemedi" kartına çevirip ekrandaki son veriyi silerdi. Bunun yerine
// son veri kalır ve "Güncellenemedi · son veri 09:41" yazar (§7.1). Uyarı,
// yeni veri gelince (generated_at değişince) kendiliğinden kalkar.
export function RefreshButton({ generatedAt, updatedHm }: { generatedAt: string; updatedHm: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [failedFor, setFailedFor] = useState<string | null>(null);
  const failed = failedFor === generatedAt;

  function refresh() {
    // disabled YERİNE aria-disabled + erken dönüş: odaktaki düğme disabled
    // olunca klavye odağı <body>'ye düşer.
    if (pending) return;
    startTransition(async () => {
      try {
        await apiClient<unknown>(DASHBOARD_PATH);
      } catch {
        startTransition(() => setFailedFor(generatedAt));
        return;
      }
      startTransition(() => {
        setFailedFor(null);
        router.refresh();
      });
    });
  }

  return (
    <>
      <p aria-live="polite" className={`text-xs tabular-nums ${failed ? "text-danger" : "text-text-muted"}`}>
        <time dateTime={generatedAt}>{failed ? COPY.refreshFailed(updatedHm) : COPY.updatedAt(updatedHm)}</time>
      </p>
      <IconButton
        label={COPY.refresh}
        aria-busy={pending}
        aria-disabled={pending}
        onClick={refresh}
        className={`aria-disabled:cursor-progress ${FOCUS_RING}`}
      >
        <RefreshCw
          size={16}
          strokeWidth={1.75}
          aria-hidden
          className={pending ? "animate-spin motion-reduce:animate-none" : ""}
        />
      </IconButton>
    </>
  );
}

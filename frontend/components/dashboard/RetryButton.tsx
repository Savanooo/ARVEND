"use client";

import { useRouter } from "next/navigation";
import { useTransition } from "react";

import { buttonClass } from "@/components/ui/styles";
import { COPY } from "@/lib/dashboard";

// "Tekrar dene": tüm özeti yeniden çeker (v1'de bölüm bazlı istek yok).
// Sürerken disabled DEĞİL aria-disabled: odaktaki düğme disabled olunca
// klavye odağı <body>'ye düşer.
export function RetryButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <button
      type="button"
      aria-disabled={pending}
      aria-busy={pending}
      onClick={() => {
        if (pending) return;
        startTransition(() => router.refresh());
      }}
      className={buttonClass("secondary", "sm")}
    >
      {COPY.retry}
    </button>
  );
}

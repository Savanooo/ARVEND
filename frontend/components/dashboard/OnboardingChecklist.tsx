"use client";

import { CircleCheckBig } from "lucide-react";
import Link from "next/link";
import { useSyncExternalStore } from "react";

import { ProgressBar } from "@/components/ui/ProgressBar";
import { FOCUS_RING, LABEL, buttonClass } from "@/components/ui/styles";
import { COPY, ONBOARDING_SETTINGS_LINK } from "@/lib/dashboard";

// Yeni firma (0 proje, 0 aktif teklif; yalnızca Sahip/Yönetici): KPI ve
// Dikkat satırının yerine "Kurulum — ilk adımlar". "Gizle" tercihi
// tarayıcıda (localStorage, firma + kullanıcı başına) tutulur; gizlenince
// tek satırlık "Kurulum rehberi gizlendi · Göster" çubuğuna iner. Sunucu
// render'ı her zaman açık listeyi çizer; tercih hydration'dan sonra
// okunur (useSyncExternalStore -> uyuşmazlık yok). localStorage erişimi
// (gizli pencere, engellenmiş site verisi) hata verirse liste açık kalır.

export interface ChecklistStep {
  key: string;
  title: string;
  helper: string | null;
  done: boolean;
  detail: string | null;
  cta: { label: string; href: string } | null;
}

const listeners = new Set<() => void>();

function subscribe(onChange: () => void) {
  listeners.add(onChange);
  window.addEventListener("storage", onChange);
  return () => {
    listeners.delete(onChange);
    window.removeEventListener("storage", onChange);
  };
}

function readHidden(key: string): boolean {
  try {
    return window.localStorage.getItem(key) === "1";
  } catch {
    return false;
  }
}

function writeHidden(key: string, hidden: boolean) {
  try {
    if (hidden) window.localStorage.setItem(key, "1");
    else window.localStorage.removeItem(key);
  } catch {
    // Tercih kaydedilemedi: yalnızca bu oturumda etkisiz kalır.
  }
  listeners.forEach((l) => l());
}

export function OnboardingChecklist({
  steps,
  doneCount,
  total,
  storageKey,
}: {
  steps: ChecklistStep[];
  doneCount: number;
  total: number;
  storageKey: string;
}) {
  const hidden = useSyncExternalStore(
    subscribe,
    () => readHidden(storageKey),
    () => false
  );

  if (hidden) {
    return (
      <section
        aria-label={COPY.onboardingTitle}
        className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-surface px-4 py-2.5"
      >
        <p className="text-sm text-text-muted">{COPY.onboardingHidden}</p>
        <button
          type="button"
          onClick={() => writeHidden(storageKey, false)}
          className={`rounded-sm text-xs font-medium text-text-muted hover:text-gold ${FOCUS_RING}`}
        >
          {COPY.onboardingShow}
        </button>
      </section>
    );
  }

  const pct = total > 0 ? (doneCount / total) * 100 : 0;
  return (
    <section aria-labelledby="kurulum-baslik" className="rounded-lg border border-border bg-surface">
      <header className="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-border px-4 py-3 @4xl:px-5">
        <h2 id="kurulum-baslik" className={LABEL}>
          {COPY.onboardingTitle}
        </h2>
        <span className="text-xs tabular-nums text-text-muted">{COPY.onboardingProgress(doneCount, total)}</span>
        <div className="w-full min-w-24 flex-1 @md:max-w-48">
          <ProgressBar
            pct={pct}
            tone="gold"
            label="Kurulum"
            valueText={COPY.onboardingProgress(doneCount, total)}
          />
        </div>
        <button
          type="button"
          onClick={() => writeHidden(storageKey, true)}
          className={`ml-auto rounded-sm text-xs font-medium text-text-muted hover:text-gold ${FOCUS_RING}`}
        >
          {COPY.onboardingHide}
        </button>
      </header>
      <ol className="divide-y divide-border">
        {steps.map((s) => (
          <li key={s.key} className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3 @4xl:px-5">
            {s.done ? (
              <CircleCheckBig size={18} strokeWidth={2} aria-hidden className="shrink-0 text-success" />
            ) : (
              <span aria-hidden className="size-[18px] shrink-0 rounded-full border-2 border-border" />
            )}
            <div className="min-w-0 flex-1">
              <p className={`text-sm ${s.done ? "text-text-muted" : "font-medium text-text"}`}>
                {s.title}
                <span className="sr-only">{s.done ? " (tamamlandı)" : " (yapılacak)"}</span>
              </p>
              {!s.done && s.helper && <p className="text-xs text-text-muted">{s.helper}</p>}
            </div>
            {s.done
              ? s.detail && <span className="text-xs tabular-nums text-text-muted">{s.detail}</span>
              : s.cta && (
                  <Link href={s.cta.href} className={buttonClass("secondary", "sm")}>
                    {s.cta.label}
                  </Link>
                )}
          </li>
        ))}
      </ol>
      <footer className="border-t border-border px-4 py-3 @4xl:px-5">
        <Link
          href={ONBOARDING_SETTINGS_LINK.href}
          className={`rounded-sm text-sm text-text-muted hover:text-gold hover:underline ${FOCUS_RING}`}
        >
          {ONBOARDING_SETTINGS_LINK.label}
        </Link>
      </footer>
    </section>
  );
}

"use client";

import { CircleAlert, Hourglass, X } from "lucide-react";
import { useSyncExternalStore } from "react";

import { FOCUS_RING } from "@/components/ui/styles";
import { istanbulDate } from "@/lib/format";
import { trialNoticeDismissKey, trialNoticeDismissedToday, type TrialNotice as Notice } from "@/lib/trial";

// Deneme süresi uyarı bandı (yalnızca Sahip/Yönetici, bkz. lib/trial.ts
// trialNoticeFor) -- mobil Ana Sayfa bandının web karşılığı; web'de her
// sayfanın üst çubuğunun altında durur. "Bugün için kapat" o İstanbul günü
// için gizler (localStorage, kişi + firma başına); ertesi gün yeniden çıkar.
// Tercih okunmadan çizilmez: sunucu render'ı ve ilk boyama bandı göstermez,
// böylece kapatılmışken bir an görünüp kaybolmaz. localStorage erişilemezse
// (gizli pencere, engellenmiş site verisi) bant görünür kalır; kapatma
// yalnızca o sayfa ömrü boyunca geçerli olur.

const listeners = new Set<() => void>();
// Kalıcı yazılamadığında bu sekmede kapatılmış sayılan anahtarlar.
const dismissedInMemory = new Map<string, string>();

function subscribe(onChange: () => void) {
  listeners.add(onChange);
  window.addEventListener("storage", onChange);
  return () => {
    listeners.delete(onChange);
    window.removeEventListener("storage", onChange);
  };
}

function readDismissedDay(key: string): string | null {
  const inMemory = dismissedInMemory.get(key);
  if (inMemory) return inMemory;
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function dismissToday(key: string) {
  const today = istanbulDate(new Date());
  dismissedInMemory.set(key, today);
  try {
    window.localStorage.setItem(key, today);
  } catch {
    // Kalıcı yazılamasa da bu sekmede gizli kalır.
  }
  listeners.forEach((l) => l());
}

export function TrialNotice({
  notice,
  organizationId,
  userId,
}: {
  notice: Notice;
  organizationId: string;
  userId: string;
}) {
  const key = trialNoticeDismissKey(organizationId, userId);
  // true = gizli. Sunucuda (ve hydration'da) gizli: tercih okunmadan çizilmez.
  const hidden = useSyncExternalStore(
    subscribe,
    () => trialNoticeDismissedToday(readDismissedDay(key), new Date()),
    () => true
  );
  if (hidden) return null;

  const Icon = notice.expired ? CircleAlert : Hourglass;
  return (
    <div
      role="status"
      className={`flex items-center gap-3 border-b px-4 py-2.5 text-sm sm:px-6 ${
        notice.expired ? "border-danger/30 bg-danger-soft" : "border-gold/30 bg-gold-soft"
      }`}
    >
      <Icon
        size={18}
        strokeWidth={1.75}
        aria-hidden
        className={`shrink-0 ${notice.expired ? "text-danger" : "text-gold"}`}
      />
      <p className="min-w-0 flex-1 leading-snug">{notice.text}</p>
      <button
        type="button"
        onClick={() => dismissToday(key)}
        title="Bugün için kapat"
        aria-label="Bugün için kapat"
        className={`shrink-0 rounded-md p-1.5 text-text-muted hover:bg-surface-hover hover:text-text ${FOCUS_RING}`}
      >
        <X size={16} strokeWidth={1.75} />
      </button>
    </div>
  );
}

"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";

import { FOCUS_RING, LABEL } from "@/components/ui/styles";
import { apiClient } from "@/lib/api";
import {
  COPY,
  NOTIFICATIONS_READ_ALL_PATH,
  notificationReadPath,
  webHrefForActionTarget,
  type DashboardResponse,
} from "@/lib/dashboard";
import { formatRelativeTime } from "@/lib/format";

import { Chip } from "./Chip";

type Notifications = NonNullable<DashboardResponse["sections"]["notifications"]>;

// "Bildirimler" (zil ile aynı anlam: yalnızca izleyicinin kendi kayıtları).
// Bildirim hedefi mobil yoludur; web karşılığı yoksa satır düz metindir.
// Bağlantılı okunmamış satıra tıklamak onu okundu işaretler (mobil ve
// üst çubuktaki zil ile aynı); istek navigasyonu beklemez.
function markRead(id: string) {
  void apiClient(notificationReadPath(id), { method: "POST", keepalive: true }).catch(() => {});
}

export function NotificationsPanel({ notifications, nowIso }: { notifications: Notifications; nowIso: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState(false);

  function markAllRead() {
    // disabled YERİNE aria-disabled + erken dönüş: odaktaki düğme disabled
    // olunca klavye odağı <body>'ye düşer.
    if (pending) return;
    setError(false);
    startTransition(async () => {
      try {
        await apiClient(NOTIFICATIONS_READ_ALL_PATH, { method: "POST" });
        router.refresh();
      } catch {
        setError(true);
      }
    });
  }

  return (
    <section
      id="bildirimler"
      aria-labelledby="bildirimler-baslik"
      className="flex h-full min-h-[17.5rem] scroll-mt-4 flex-col rounded-lg border border-border bg-surface"
    >
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-3 @4xl/home:px-5">
        <h2 id="bildirimler-baslik" className={LABEL}>
          {COPY.notifications}
        </h2>
        {/* Nötr sayaç: okunmamış bir "aksiyon" değil (D7); altın yalnızca satır noktasında. */}
        {notifications.unread > 0 && <Chip tone="muted">{COPY.unread(notifications.unread)}</Chip>}
      </header>
      {notifications.latest.length === 0 ? (
        <p className="px-4 py-4 text-sm text-text-muted @4xl/home:px-5">{COPY.notificationsEmpty}</p>
      ) : (
        <ul className="divide-y divide-border py-1">
          {notifications.latest.slice(0, 5).map((n) => {
            const href = webHrefForActionTarget(n.action_target);
            const unread = n.read_at === null;
            const content = (
              <>
                <span
                  aria-hidden
                  className={`mt-1.5 size-2 shrink-0 rounded-full ${unread ? "bg-gold" : "bg-transparent"}`}
                />
                <span className="min-w-0 flex-1">
                  <span className={`block text-sm text-text ${unread ? "font-semibold" : ""}`}>
                    {n.title}
                    {unread && <span className="sr-only"> (okunmamış)</span>}
                  </span>
                  {n.body && <span className="block truncate text-xs text-text-muted">{n.body}</span>}
                </span>
                <time dateTime={n.created_at} className="shrink-0 text-xs whitespace-nowrap tabular-nums text-text-muted">
                  {formatRelativeTime(n.created_at, nowIso)}
                </time>
              </>
            );
            const cls = "flex min-h-11 items-start gap-3 px-4 py-2.5 @4xl/home:px-5";
            return (
              <li key={n.id}>
                {href ? (
                  <Link
                    href={href}
                    onClick={unread ? () => markRead(n.id) : undefined}
                    className={`${cls} transition-colors hover:bg-gold-soft/30 ${FOCUS_RING}`}
                  >
                    {content}
                  </Link>
                ) : (
                  <div className={cls}>{content}</div>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {(notifications.unread > 0 || error) && (
        <footer className="mt-auto flex flex-wrap items-center justify-between gap-2 border-t border-border px-4 py-2 @4xl/home:px-5">
          {error ? <p className="text-xs text-danger">{COPY.markAllReadFailed}</p> : <span />}
          {notifications.unread > 0 && (
            <button
              type="button"
              onClick={markAllRead}
              aria-disabled={pending}
              aria-busy={pending}
              className={`inline-flex min-h-9 items-center rounded-sm text-xs font-medium text-text-muted hover:text-gold aria-disabled:cursor-progress aria-disabled:opacity-50 ${FOCUS_RING}`}
            >
              {COPY.markAllRead}
            </button>
          )}
        </footer>
      )}
    </section>
  );
}

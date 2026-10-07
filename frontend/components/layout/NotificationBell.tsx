"use client";

import { Bell } from "lucide-react";
import { usePathname, useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";

import { FOCUS_RING } from "@/components/ui/styles";
import { apiClient } from "@/lib/api";
import {
  COPY,
  NOTIFICATIONS_LIST_PATH,
  NOTIFICATIONS_READ_ALL_PATH,
  NOTIFICATIONS_UNREAD_COUNT_PATH,
  notificationReadPath,
  webHrefForActionTarget,
} from "@/lib/dashboard";
import { formatRelativeTime } from "@/lib/format";

interface NotificationItem {
  id: string;
  title: string;
  body: string;
  action_target: string;
  read_at: string | null;
  created_at: string;
}

const POLL_MS = 60_000;

// Üst çubuk zili: okunmamış sayısı + son 10 bildirim. Backend uçları
// (GET /notifications, /unread-count, POST /{id}/read, /read-all) her
// zaman çağıranın KENDİ kayıtlarını döner. Bildirime tıklamak onu okundu
// işaretler ve web karşılığı varsa ilgili sayfayı açar (hedef mobil
// yoludur, bkz. webHrefForActionTarget).
export function NotificationBell() {
  const router = useRouter();
  const pathname = usePathname();
  const ref = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [unread, setUnread] = useState(0);
  const [items, setItems] = useState<NotificationItem[] | null>(null);
  const [failed, setFailed] = useState(false);

  const loadCount = useCallback(async () => {
    try {
      const res = await apiClient<{ unread_count: number }>(NOTIFICATIONS_UNREAD_COUNT_PATH);
      setUnread(res.unread_count);
    } catch {
      // Sayaç yardımcıdır; alınamazsa zil sessiz kalır.
    }
  }, []);

  // Sayfa değiştikçe ve sekme açıkken dakikada bir tazelenir.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- ağdan senkronizasyon
    void loadCount();
  }, [pathname, loadCount]);

  useEffect(() => {
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") void loadCount();
    }, POLL_MS);
    return () => clearInterval(timer);
  }, [loadCount]);

  useEffect(() => {
    if (!open) return;
    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    function handleEscape(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", handleClick);
    document.addEventListener("keydown", handleEscape);
    return () => {
      document.removeEventListener("mousedown", handleClick);
      document.removeEventListener("keydown", handleEscape);
    };
  }, [open]);

  async function toggle() {
    const next = !open;
    setOpen(next);
    if (!next) return;
    setFailed(false);
    try {
      const res = await apiClient<{ notifications: NotificationItem[] }>(`${NOTIFICATIONS_LIST_PATH}?limit=10`);
      setItems(res.notifications ?? []);
      void loadCount();
    } catch {
      setFailed(true);
    }
  }

  function openItem(n: NotificationItem) {
    if (!n.read_at) {
      const now = new Date().toISOString();
      setItems((prev) => prev?.map((x) => (x.id === n.id ? { ...x, read_at: now } : x)) ?? prev);
      setUnread((u) => Math.max(0, u - 1));
      void apiClient(notificationReadPath(n.id), { method: "POST", keepalive: true }).catch(() => {});
    }
    const href = webHrefForActionTarget(n.action_target);
    if (href) {
      setOpen(false);
      router.push(href);
    }
  }

  async function markAllRead() {
    try {
      await apiClient(NOTIFICATIONS_READ_ALL_PATH, { method: "POST" });
      const now = new Date().toISOString();
      setItems((prev) => prev?.map((x) => (x.read_at ? x : { ...x, read_at: now })) ?? prev);
      setUnread(0);
      // Ana sayfadaki Bildirimler paneli de güncellensin.
      router.refresh();
    } catch {
      setFailed(true);
    }
  }

  const nowIso = new Date().toISOString();

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={toggle}
        aria-haspopup="true"
        aria-expanded={open}
        aria-label={unread > 0 ? `${COPY.notifications} (${COPY.unread(unread)})` : COPY.notifications}
        title={COPY.notifications}
        className={`relative rounded-md p-2 text-text-muted transition-colors hover:bg-surface-hover hover:text-text ${FOCUS_RING}`}
      >
        <Bell size={18} strokeWidth={1.75} />
        {unread > 0 && (
          <span className="absolute -right-0.5 -top-0.5 min-w-4 rounded-full bg-gold px-1 text-center text-[10px] font-semibold leading-4 text-text">
            {unread > 9 ? "9+" : unread}
          </span>
        )}
      </button>
      {open && (
        <div className="fixed inset-x-4 top-14 z-30 flex max-h-[28rem] flex-col rounded-md border border-border bg-surface text-sm shadow-md sm:absolute sm:inset-x-auto sm:right-0 sm:top-auto sm:mt-1 sm:w-80">
          <div className="flex items-center justify-between border-b border-border px-3 py-2">
            <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">{COPY.notifications}</span>
            {unread > 0 && (
              <button type="button" onClick={markAllRead} className="text-xs text-text-muted hover:text-gold">
                {COPY.markAllRead}
              </button>
            )}
          </div>
          <div className="overflow-y-auto">
            {failed ? (
              <p className="px-3 py-4 text-xs text-danger">Bildirimler alınamadı.</p>
            ) : items === null ? (
              <p className="px-3 py-4 text-xs text-text-muted">Yükleniyor…</p>
            ) : items.length === 0 ? (
              <p className="px-3 py-4 text-xs text-text-muted">{COPY.notificationsEmpty}</p>
            ) : (
              <ul className="divide-y divide-border">
                {items.map((n) => {
                  const isUnread = n.read_at === null;
                  return (
                    <li key={n.id}>
                      <button
                        type="button"
                        onClick={() => openItem(n)}
                        className="flex w-full items-start gap-2 px-3 py-2.5 text-left hover:bg-surface-hover"
                      >
                        <span
                          aria-hidden
                          className={`mt-1.5 size-2 shrink-0 rounded-full ${isUnread ? "bg-gold" : "bg-transparent"}`}
                        />
                        <span className="min-w-0 flex-1">
                          <span className={`block text-sm text-text ${isUnread ? "font-semibold" : ""}`}>
                            {n.title}
                            {isUnread && <span className="sr-only"> (okunmamış)</span>}
                          </span>
                          {n.body && <span className="block truncate text-xs text-text-muted">{n.body}</span>}
                          <span className="block text-[11px] text-text-muted">
                            {formatRelativeTime(n.created_at, nowIso)}
                          </span>
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

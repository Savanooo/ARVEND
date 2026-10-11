"use client";

import {
  Handshake,
  HardHat,
  Hourglass,
  IdCard,
  MessageSquareText,
  PackageSearch,
  Receipt,
  Sparkles,
  type LucideIcon,
} from "lucide-react";
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";

import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { canAccess } from "@/lib/permissions";
import type { Role } from "@/lib/types";
import {
  WHATS_NEW_RELEASES,
  hasUnseenRelease,
  latestWhatsNew,
  whatsNewSeenKey,
  whatsNewSince,
  type WhatsNewIcon,
  type WhatsNewNotes,
  type WhatsNewViewer,
} from "@/lib/whats-new";

// "Yenilikler": güncellemeden sonraki ilk girişte bir kez açılan kısa
// pencere + sidebar altındaki "Yenilikler" düğmesiyle tekrar açma (mobil
// Diğer > Hakkında > Yenilikler karşılığı). İçerik ve kurallar
// lib/whats-new.ts'te. "Görüldü" kaydı localStorage'da (kişi başına);
// mobildeki gibi pencere AÇILIR AÇILMAZ yazılır -- kapatmadan sayfa
// yenilense de ikinci kez çıkmaz. Hiçbir hata kabuğu bozmaz: kayıt
// okunamazsa (gizli pencere, engellenmiş site verisi) pencere
// kendiliğinden açılmaz -- her sayfa yüklemesinde yeniden çıkmasındansa
// hiç çıkmaması yeğ.

const ICONS: Record<WhatsNewIcon, LucideIcon> = {
  subcontracts: HardHat,
  expenses: Receipt,
  catalog: PackageSearch,
  "change-order": Handshake,
  "task-notes": MessageSquareText,
  trial: Hourglass,
  person: IdCard,
};

// Sunucuda ve hydration'da "en yeni yayın görüldü" sayılır: pencere yalnızca
// tarayıcıda, kayıt okunduktan sonra açılır.
const LATEST_KEY = WHATS_NEW_RELEASES[0]?.key ?? null;

// Sayfa yüklemesindeki ilk okuma (anahtar başına): kayıt pencere açılır
// açılmaz yazıldığı için karar bu ilk değere göre verilir -- yoksa yazma
// pencereyi anında kapatırdı. Pencere kapanınca "görüldü"ye çekilir ki
// başka bir bölüme geçince (kabuk yeniden kurulur) tekrar açılmasın.
const seenAtLoad = new Map<string, string | null>();

function readSeenAtLoad(storageKey: string): string | null {
  if (!seenAtLoad.has(storageKey)) {
    let seen: string | null;
    try {
      seen = window.localStorage.getItem(storageKey);
    } catch {
      seen = LATEST_KEY;
    }
    seenAtLoad.set(storageKey, seen);
  }
  return seenAtLoad.get(storageKey) ?? null;
}

// Değer sayfa ömrü boyunca sabit: dinlenecek bir değişiklik yok.
function subscribe() {
  return () => {};
}

function writeSeen(storageKey: string) {
  if (!LATEST_KEY) return;
  try {
    window.localStorage.setItem(storageKey, LATEST_KEY);
  } catch {
    // Yazılamazsa en kötü ihtimalle bir sonraki girişte yine gösterilir.
  }
}

export function WhatsNew({
  userId,
  role,
  permissions,
  trialOwnerAdmin,
  collapsed = false,
}: {
  userId: string;
  role: Role;
  permissions?: string[];
  trialOwnerAdmin: boolean;
  collapsed?: boolean;
}) {
  const storageKey = whatsNewSeenKey(userId);
  const viewer = useMemo<WhatsNewViewer>(
    () => ({ can: (code) => canAccess({ role, permissions }, code), trialOwnerAdmin }),
    [role, permissions, trialOwnerAdmin]
  );
  const lastSeen = useSyncExternalStore(
    subscribe,
    () => readSeenAtLoad(storageKey),
    () => LATEST_KEY
  );
  const pending = useMemo(() => whatsNewSince(lastSeen, viewer), [lastSeen, viewer]);
  const latest = useMemo(() => latestWhatsNew(viewer), [viewer]);
  const [manual, setManual] = useState<WhatsNewNotes | null>(null);
  const [dismissed, setDismissed] = useState(false);

  // Görülmemiş yayın: pencere açılırken "görüldü" yazılır. Kişinin
  // görebileceği madde yoksa pencere hiç açılmaz ama yayın yine yazılır --
  // her girişte aynı karar yeniden verilmesin.
  useEffect(() => {
    if (hasUnseenRelease(lastSeen)) writeSeen(storageKey);
  }, [lastSeen, storageKey]);

  const notes = manual ?? (dismissed ? null : pending);

  function close() {
    setManual(null);
    setDismissed(true);
    seenAtLoad.set(storageKey, LATEST_KEY);
  }

  return (
    <>
      {latest && (
        <button
          type="button"
          onClick={() => setManual(latest)}
          title={collapsed ? "Yenilikler" : undefined}
          aria-label="Yenilikler"
          className="sidebar-nav-link flex items-center gap-2 rounded-md px-2 py-1.5 text-xs font-semibold uppercase tracking-widest"
        >
          <Sparkles size={16} strokeWidth={1.75} />
          {!collapsed && <span className="sidebar-label">Yenilikler</span>}
        </button>
      )}
      {notes && (
        <Modal
          open
          onClose={close}
          title="Yenilikler"
          footer={
            <Button type="button" onClick={close}>
              Tamam
            </Button>
          }
        >
          <p className="mb-3 text-xs font-semibold uppercase tracking-widest text-text-muted">{notes.label} · Web</p>
          <ul className="flex flex-col gap-3">
            {notes.items.map((item) => {
              const Icon = ICONS[item.icon];
              return (
                <li key={item.title} className="flex items-start gap-3">
                  <span className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-md bg-gold-soft text-gold">
                    <Icon size={16} strokeWidth={1.75} aria-hidden />
                  </span>
                  <div className="min-w-0">
                    <p className="font-medium">{item.title}</p>
                    <p className="text-text-muted">{item.body}</p>
                  </div>
                </li>
              );
            })}
          </ul>
        </Modal>
      )}
    </>
  );
}

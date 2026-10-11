import {
  Bell,
  CalendarDays,
  Camera,
  FilePlus,
  FileText,
  FolderCog,
  Handshake,
  ListChecks,
  type LucideIcon,
  Megaphone,
  Paperclip,
  Receipt,
  ReceiptText,
  Scale,
  ShoppingCart,
  Truck,
  Wallet,
} from "lucide-react";

import { NOTIFICATION_KIND_LABELS, notificationKind, type NotificationKind } from "@/lib/notifications";

// Bildirim türü -> simge (mobil notifications_screen.dart _icon ile aynı
// anlam). Tür, entity_type'tan (zil) ya da type'tan (ana sayfa paneli)
// türetilir -- bkz. lib/notifications.ts.
const ICONS: Record<NotificationKind, LucideIcon> = {
  task: ListChecks,
  offer: FileText,
  change_order: FilePlus,
  subcontract: Handshake,
  subcontract_change_order: FolderCog,
  progress_claim: ReceiptText,
  purchase_request: ShoppingCart,
  rfq: Scale,
  purchase_order: Truck,
  budget_adjustment: Wallet,
  announcement: Megaphone,
  schedule_item: CalendarDays,
  project_photo: Camera,
  project_file: Paperclip,
  project_expense: Receipt,
  other: Bell,
};

// Nötr (altın değil): okunmamışlığı yalnızca satırdaki altın nokta söyler
// (ana sayfa D7 ilkesi).
export function NotificationIcon({ notification }: { notification: { entity_type?: string | null; type?: string | null } }) {
  const kind = notificationKind(notification);
  const Icon = ICONS[kind];
  const label = NOTIFICATION_KIND_LABELS[kind];
  return (
    <span
      title={label}
      className="flex size-7 shrink-0 items-center justify-center rounded-md bg-surface-hover text-text-muted"
    >
      <Icon size={14} strokeWidth={1.75} aria-hidden />
      <span className="sr-only">{label}</span>
    </span>
  );
}

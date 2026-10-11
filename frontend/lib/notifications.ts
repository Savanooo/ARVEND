// Bildirim satırının türü (simge + kısa etiket) -- üst çubuk zili ve ana
// sayfanın Bildirimler paneli kullanır, node testleri (notifications.test.mts)
// içe aktarır. Mobil notifications_screen.dart _NotificationTile._icon ile
// aynı eşleme. Simgeler components/layout/NotificationIcon.tsx'tedir (bu
// modül React/lucide içermez).

export type NotificationKind =
  | "task"
  | "offer"
  | "change_order"
  | "subcontract"
  | "subcontract_change_order"
  | "progress_claim"
  | "purchase_request"
  | "rfq"
  | "purchase_order"
  | "budget_adjustment"
  | "announcement"
  | "schedule_item"
  | "project_photo"
  | "project_file"
  | "project_expense"
  | "other";

// backend domain.NotificationEntity* (+ duyuru) -- türün asıl kaynağı.
const ENTITY_KINDS: ReadonlySet<string> = new Set<NotificationKind>([
  "task",
  "offer",
  "change_order",
  "subcontract",
  "subcontract_change_order",
  "progress_claim",
  "purchase_request",
  "rfq",
  "purchase_order",
  "budget_adjustment",
  "announcement",
  "schedule_item",
  "project_photo",
  "project_file",
  "project_expense",
]);

// Ana sayfa özetinin bildirim satırı entity_type TAŞIMAZ, yalnızca type --
// tür, backend domain.Notification* sabitlerinden türetilir. Sıra önemli:
// "subcontract_change_order_" "subcontract_"tan, "change_order_" ise ikisinden
// sonra denenir.
const TYPE_PREFIX_KINDS: readonly [string, NotificationKind][] = [
  ["task_", "task"],
  ["offer_", "offer"],
  ["subcontract_change_order_", "subcontract_change_order"],
  ["subcontract_", "subcontract"],
  ["change_order_", "change_order"],
  ["progress_claim_", "progress_claim"],
  ["purchase_request_", "purchase_request"],
  ["rfq_", "rfq"],
  ["purchase_order_", "purchase_order"],
  ["budget_adjustment_", "budget_adjustment"],
  ["schedule_", "schedule_item"],
  ["photo_", "project_photo"],
  ["file_", "project_file"],
  ["expense_", "project_expense"],
];

/** Bildirimin türü: entity_type tanınıyorsa o, yoksa type'tan; bilinmeyen "other". */
export function notificationKind(n: { entity_type?: string | null; type?: string | null }): NotificationKind {
  if (n.entity_type && ENTITY_KINDS.has(n.entity_type)) return n.entity_type as NotificationKind;
  const type = n.type ?? "";
  if (type === "announcement") return "announcement";
  for (const [prefix, kind] of TYPE_PREFIX_KINDS) {
    if (type.startsWith(prefix)) return kind;
  }
  return "other";
}

/** Simgenin erişilebilir adı (title / ekran okuyucu). */
export const NOTIFICATION_KIND_LABELS: Record<NotificationKind, string> = {
  task: "Görev",
  offer: "Teklif",
  change_order: "Ek İş",
  subcontract: "Taşeron Sözleşmesi",
  subcontract_change_order: "Taşeron Değişiklik Emri",
  progress_claim: "Hakediş",
  purchase_request: "Satın Alma Talebi",
  rfq: "Fiyat Talebi (RFQ)",
  purchase_order: "Sipariş",
  budget_adjustment: "Bütçe Revizyonu",
  announcement: "Duyuru",
  schedule_item: "Planlama",
  project_photo: "Şantiye Fotoğrafı",
  project_file: "Dosya",
  project_expense: "Masraf",
  other: "Bildirim",
};

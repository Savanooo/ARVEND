import type { Tone } from "@/components/ui/Badge";
import {
  ADJUSTMENT_STATUS_LABELS,
  BUDGET_STATUS_LABELS,
  CHANGE_ORDER_STATUS_LABELS,
  COMMITMENT_STATUS_LABELS,
  CONTRACT_STATUS_LABELS,
  EXPENSE_APPROVAL_STATUS_LABELS,
  INVOICE_STATUS_LABELS,
  ORG_STATUS_LABELS,
  PLAN_ITEM_STATUS_LABELS,
  PROJECT_STATUS_LABELS,
  PURCHASE_ORDER_STATUS_LABELS,
  PURCHASE_REQUEST_STATUS_LABELS,
  RFQ_STATUS_LABELS,
  SCHEDULE_STATUS_LABELS,
  SUBCONTRACTOR_STATUS_LABELS,
  TASK_STATUS_LABELS,
  type AdjustmentStatus,
  type AttendanceStatus,
  type BudgetStatus,
  type ChangeOrderStatus,
  type CommitmentStatus,
  type ContractStatus,
  type ExpenseApprovalStatus,
  type InvoiceStatus,
  type OfferStatus,
  type OrgStatus,
  type PlanItemStatus,
  type ProjectStatus,
  type PurchaseOrderStatus,
  type PurchaseRequestStatus,
  type RFQStatus,
  type ScheduleStatus,
  type SubcontractorStatus,
  type TaskStatus,
} from "./types";

export interface StatusMeta {
  label: string;
  tone: Tone;
}

// Tek doğruluk kaynağı: önceden 11 ayrı dosyada (+ bir inline ternary,
// toplam 12) tekrarlanan durum->renk eşlemesi burada birleşiyor.
// Etiketler, zaten var olan lib/types.ts'teki *_LABELS sözlüklerinden
// alınır (yalnızca OfferStatus ve AttendanceStatus'ta böyle bir sözlük
// yoktu, burada ilk kez tanımlandı) -- yalnızca `tone` yeni bir karar.
//
// "gönderildi"/"sent" (müşteriye gönderilip yanıt beklenen) anlamına
// gelen HER durum -- OfferStatus, ChangeOrderStatus, InvoiceStatus --
// tutarlılık için "info" (mavi) tonuna sahiptir. Bu, "devam ediyor"
// (ProjectStatus.active, ScheduleStatus.active, TaskStatus.in_progress)
// ile KARIŞTIRILMAMALI -- o kavram hâlâ gold'dur (bkz. aşağı), çünkü
// anlamca farklıdır (bir şeyin sürmesi vs. dışarıya gönderilip cevap
// beklenmesi).

export const OFFER_STATUS: Record<OfferStatus, StatusMeta> = {
  taslak: { label: "Taslak", tone: "muted" },
  gönderildi: { label: "Gönderildi", tone: "info" },
  "kabul edildi": { label: "Kabul Edildi", tone: "success" },
  reddedildi: { label: "Reddedildi", tone: "danger" },
};

export const PROJECT_STATUS: Record<ProjectStatus, StatusMeta> = {
  planned: { label: PROJECT_STATUS_LABELS.planned, tone: "muted" },
  active: { label: PROJECT_STATUS_LABELS.active, tone: "gold" },
  paused: { label: PROJECT_STATUS_LABELS.paused, tone: "muted" },
  completed: { label: PROJECT_STATUS_LABELS.completed, tone: "success" },
  cancelled: { label: PROJECT_STATUS_LABELS.cancelled, tone: "danger" },
};

export const CHANGE_ORDER_STATUS: Record<ChangeOrderStatus, StatusMeta> = {
  draft: { label: CHANGE_ORDER_STATUS_LABELS.draft, tone: "muted" },
  sent: { label: CHANGE_ORDER_STATUS_LABELS.sent, tone: "info" },
  approved: { label: CHANGE_ORDER_STATUS_LABELS.approved, tone: "success" },
  rejected: { label: CHANGE_ORDER_STATUS_LABELS.rejected, tone: "danger" },
  cancelled: { label: CHANGE_ORDER_STATUS_LABELS.cancelled, tone: "danger" },
  superseded: { label: CHANGE_ORDER_STATUS_LABELS.superseded, tone: "muted" },
};

export const PLAN_ITEM_STATUS: Record<PlanItemStatus, StatusMeta> = {
  pending: { label: PLAN_ITEM_STATUS_LABELS.pending, tone: "muted" },
  partial: { label: PLAN_ITEM_STATUS_LABELS.partial, tone: "gold" },
  paid: { label: PLAN_ITEM_STATUS_LABELS.paid, tone: "success" },
  overdue: { label: PLAN_ITEM_STATUS_LABELS.overdue, tone: "danger" },
  cancelled: { label: PLAN_ITEM_STATUS_LABELS.cancelled, tone: "muted" },
};

export const INVOICE_STATUS: Record<InvoiceStatus, StatusMeta> = {
  draft: { label: INVOICE_STATUS_LABELS.draft, tone: "muted" },
  issued: { label: INVOICE_STATUS_LABELS.issued, tone: "gold" },
  sent: { label: INVOICE_STATUS_LABELS.sent, tone: "info" },
  paid: { label: INVOICE_STATUS_LABELS.paid, tone: "success" },
  cancelled: { label: INVOICE_STATUS_LABELS.cancelled, tone: "danger" },
};

export const SCHEDULE_STATUS: Record<ScheduleStatus, StatusMeta> = {
  planned: { label: SCHEDULE_STATUS_LABELS.planned, tone: "muted" },
  active: { label: SCHEDULE_STATUS_LABELS.active, tone: "gold" },
  completed: { label: SCHEDULE_STATUS_LABELS.completed, tone: "success" },
  cancelled: { label: SCHEDULE_STATUS_LABELS.cancelled, tone: "danger" },
};

export const TASK_STATUS: Record<TaskStatus, StatusMeta> = {
  todo: { label: TASK_STATUS_LABELS.todo, tone: "muted" },
  in_progress: { label: TASK_STATUS_LABELS.in_progress, tone: "gold" },
  completed: { label: TASK_STATUS_LABELS.completed, tone: "success" },
  cancelled: { label: TASK_STATUS_LABELS.cancelled, tone: "danger" },
};

// Önceden FinanceSections.tsx'te adsız bir inline ternary idi (bkz.
// denetim) -- planned/active/completed/cancelled şekli diğer
// enum'larla (ör. ScheduleStatus) birebir aynı olduğundan AYNI
// muted/gold/success/danger kuralı uygulanır.
export const SUBCONTRACTOR_STATUS: Record<SubcontractorStatus, StatusMeta> = {
  planned: { label: SUBCONTRACTOR_STATUS_LABELS.planned, tone: "muted" },
  active: { label: SUBCONTRACTOR_STATUS_LABELS.active, tone: "gold" },
  completed: { label: SUBCONTRACTOR_STATUS_LABELS.completed, tone: "success" },
  cancelled: { label: SUBCONTRACTOR_STATUS_LABELS.cancelled, tone: "danger" },
};

export const ATTENDANCE_STATUS: Record<AttendanceStatus, StatusMeta> = {
  geldi: { label: "Geldi", tone: "success" },
  "yarım gün": { label: "Yarım Gün", tone: "gold" },
  gelmedi: { label: "Gelmedi", tone: "danger" },
  izinli: { label: "İzinli", tone: "muted" },
};

// Sprint 2 — WBS + Maliyet Kodları + Proje Bütçesi + Maliyet Kontrolü.
export const BUDGET_STATUS: Record<BudgetStatus, StatusMeta> = {
  draft: { label: BUDGET_STATUS_LABELS.draft, tone: "muted" },
  baselined: { label: BUDGET_STATUS_LABELS.baselined, tone: "success" },
};

export const ADJUSTMENT_STATUS: Record<AdjustmentStatus, StatusMeta> = {
  draft: { label: ADJUSTMENT_STATUS_LABELS.draft, tone: "muted" },
  approved: { label: ADJUSTMENT_STATUS_LABELS.approved, tone: "success" },
  rejected: { label: ADJUSTMENT_STATUS_LABELS.rejected, tone: "danger" },
};

// Onay bekleyen masraf, gönderilip karar beklenen talep gibi "info" --
// satın alma talebinin "submitted" tonuyla aynı.
export const EXPENSE_APPROVAL_STATUS: Record<ExpenseApprovalStatus, StatusMeta> = {
  pending: { label: EXPENSE_APPROVAL_STATUS_LABELS.pending, tone: "info" },
  approved: { label: EXPENSE_APPROVAL_STATUS_LABELS.approved, tone: "success" },
  rejected: { label: EXPENSE_APPROVAL_STATUS_LABELS.rejected, tone: "danger" },
};

export const COMMITMENT_STATUS: Record<CommitmentStatus, StatusMeta> = {
  active: { label: COMMITMENT_STATUS_LABELS.active, tone: "gold" },
  voided: { label: COMMITMENT_STATUS_LABELS.voided, tone: "danger" },
};

export const ORG_STATUS: Record<OrgStatus, StatusMeta> = {
  active: { label: ORG_STATUS_LABELS.active, tone: "success" },
  trial: { label: ORG_STATUS_LABELS.trial, tone: "info" },
  suspended: { label: ORG_STATUS_LABELS.suspended, tone: "danger" },
  cancelled: { label: ORG_STATUS_LABELS.cancelled, tone: "muted" },
};

// Sprint 3 — Proje Sözleşmesi (Contract, gelir tarafı). "active" burada
// PROJECT_STATUS.active/SCHEDULE_STATUS.active ile aynı "yürürlükte"
// anlamına gelir (gold) -- ChangeOrderStatus.sent'in "gönderildi, yanıt
// bekleniyor" anlamındaki info tonuyla KARIŞTIRILMAMALI.
export const CONTRACT_STATUS: Record<ContractStatus, StatusMeta> = {
  draft: { label: CONTRACT_STATUS_LABELS.draft, tone: "muted" },
  active: { label: CONTRACT_STATUS_LABELS.active, tone: "gold" },
  completed: { label: CONTRACT_STATUS_LABELS.completed, tone: "success" },
  cancelled: { label: CONTRACT_STATUS_LABELS.cancelled, tone: "danger" },
  terminated: { label: CONTRACT_STATUS_LABELS.terminated, tone: "danger" },
};

// Sprint 4 — Procurement Foundation. "submitted"/"issued" (onay/yanıt
// bekleniyor) OfferStatus.gönderildi/ChangeOrderStatus.sent İLE AYNI
// "info" tonu ilkesini izler.
export const PURCHASE_REQUEST_STATUS: Record<PurchaseRequestStatus, StatusMeta> = {
  draft: { label: PURCHASE_REQUEST_STATUS_LABELS.draft, tone: "muted" },
  submitted: { label: PURCHASE_REQUEST_STATUS_LABELS.submitted, tone: "info" },
  approved: { label: PURCHASE_REQUEST_STATUS_LABELS.approved, tone: "success" },
  rejected: { label: PURCHASE_REQUEST_STATUS_LABELS.rejected, tone: "danger" },
  cancelled: { label: PURCHASE_REQUEST_STATUS_LABELS.cancelled, tone: "danger" },
};

export const RFQ_STATUS: Record<RFQStatus, StatusMeta> = {
  draft: { label: RFQ_STATUS_LABELS.draft, tone: "muted" },
  issued: { label: RFQ_STATUS_LABELS.issued, tone: "info" },
  closed: { label: RFQ_STATUS_LABELS.closed, tone: "success" },
  cancelled: { label: RFQ_STATUS_LABELS.cancelled, tone: "danger" },
};

export const PURCHASE_ORDER_STATUS: Record<PurchaseOrderStatus, StatusMeta> = {
  draft: { label: PURCHASE_ORDER_STATUS_LABELS.draft, tone: "muted" },
  approved: { label: PURCHASE_ORDER_STATUS_LABELS.approved, tone: "gold" },
  cancelled: { label: PURCHASE_ORDER_STATUS_LABELS.cancelled, tone: "danger" },
  closed: { label: PURCHASE_ORDER_STATUS_LABELS.closed, tone: "success" },
};

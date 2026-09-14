export type Role = "admin" | "kullanici";

export interface User {
  id: string;
  username: string;
  full_name: string;
  role: Role;
  is_active?: boolean;
}

export interface ApiErrorBody {
  error: string;
}

export interface Product {
  id: string;
  name: string;
  unit: string;
  unit_price: number;
  description: string;
  category: string;
}

export interface PriceHistoryEntry {
  old_price: number;
  new_price: number;
  changed_at: string;
}

export type OfferStatus = "taslak" | "gönderildi" | "kabul edildi" | "reddedildi";

export interface OfferItem {
  id: string;
  product_id: string | null;
  product_name: string;
  quantity: number;
  unit_price: number;
  line_total: number;
}

export interface Customer {
  id: string;
  name: string;
  phone: string;
  email: string;
  address: string;
  tax_office: string;
  tax_number: string;
  notes: string;
  is_active: boolean;
}

export interface Offer {
  id: string;
  offer_no: string;
  revision_no: number;
  customer_id: string | null;
  customer_name: string;
  customer_phone: string;
  customer_email: string;
  customer_address: string;
  offer_date: string;
  valid_until: string | null;
  subtotal: number;
  vat_rate: number;
  vat_amount: number;
  grand_total: number;
  notes: string;
  status: OfferStatus;
  is_passive: boolean;
  items?: OfferItem[];
}

export interface OfferShareLink {
  id: string;
  offer_id: string;
  revision_id: string;
  token: string;
  created_by: string | null;
  created_at: string;
  expires_at: string | null;
  revoked_at: string | null;
  is_active: boolean;
}

export type OfferEventType =
  | "offer_created"
  | "offer_updated"
  | "revision_created"
  | "revision_sent"
  | "share_link_created"
  | "share_link_revoked"
  | "customer_viewed"
  | "customer_accepted"
  | "customer_rejected"
  | "email_sent"
  | "email_failed"
  | "offer_cancelled"
  | "project_created";

export interface OfferEvent {
  id: string;
  revision_id: string | null;
  event_type: OfferEventType;
  user_id: string | null;
  metadata?: Record<string, unknown>;
  created_at: string;
}

export interface OfferEmailLog {
  id: string;
  revision_id: string;
  recipient: string;
  subject: string;
  status: "sent" | "failed";
  error_message: string;
  sent_by: string | null;
  sent_at: string;
}

export interface OfferRevision {
  id: string;
  offer_id: string;
  revision_no: number;
  customer_id: string | null;
  customer_name: string;
  customer_phone: string;
  customer_email: string;
  customer_address: string;
  valid_until: string | null;
  subtotal: number;
  vat_rate: number;
  vat_amount: number;
  grand_total: number;
  currency: string;
  notes: string;
  status: OfferStatus;
  created_by: string | null;
  created_at: string;
  items?: OfferItem[];
}

export type ProjectStatus = "planned" | "active" | "paused" | "completed" | "cancelled";

export const PROJECT_STATUS_LABELS: Record<ProjectStatus, string> = {
  planned: "Planlandı",
  active: "Devam Ediyor",
  paused: "Beklemede",
  completed: "Tamamlandı",
  cancelled: "İptal",
};

export interface Project {
  id: string;
  project_no: string;
  name: string;
  project_type: string;
  source_offer_id: string;
  source_offer_no: string;
  source_revision_id: string;
  source_revision_no: number;
  customer_id: string | null;
  customer_name: string;
  customer_phone: string;
  customer_email: string;
  customer_address: string;
  contract_amount: number;
  currency: string;
  status: ProjectStatus;
  start_date: string | null;
  end_date: string | null;
  description: string;
  internal_notes: string;
  created_by: string | null;
  created_at: string;
  updated_at: string;

  // Liste ekranının finans kolonları (backend'de aggregate edilir).
  collected_amount?: number;
  total_expenses?: number;
  subcontractor_paid?: number;
  subcontractor_remaining?: number;
  remaining_receivable?: number;
  realized_cost?: number;
  realized_gross_profit?: number;
  invoice_count?: number;
  paid_invoice_count?: number;
  // Faz 8: onaylı ek iş/eksiltme net etkisi ve ondan türetilen güncel
  // proje bedeli. contract_amount (ana sözleşme) ASLA değişmez.
  change_order_net?: number;
  current_contract_value?: number;
}

export interface Employee {
  id: string;
  full_name: string;
  phone: string;
  position: string;
  salary: number | null;
  daily_wage: number | null;
  start_date: string | null;
  is_active: boolean;
  description: string;
}

export interface SmtpSettings {
  host: string;
  port: number;
  username: string;
  password_set: boolean;
  from_email: string;
  from_name: string;
  use_tls: boolean;
  configured: boolean;
}

export type AttendanceStatus = "geldi" | "yarım gün" | "gelmedi" | "izinli";

export interface AttendanceLog {
  id: string;
  employee_id: string;
  employee_name?: string;
  date: string;
  check_in: string;
  check_out: string;
  work_hours: number;
  status: AttendanceStatus;
  note: string;
}

// ---------- Faz 6: proje finans ----------

export type PlanItemStatus = "pending" | "partial" | "paid" | "overdue" | "cancelled";

export const PLAN_ITEM_STATUS_LABELS: Record<PlanItemStatus, string> = {
  pending: "Bekliyor",
  partial: "Kısmi Tahsil",
  paid: "Tahsil Edildi",
  overdue: "Gecikti",
  cancelled: "İptal",
};

export interface PaymentPlanItem {
  id: string;
  sort_order: number;
  name: string;
  percentage: number | null;
  planned_amount: number;
  collected_amount: number;
  remaining_amount: number;
  due_date: string | null;
  status: PlanItemStatus;
  notes: string;
}

export interface Collection {
  id: string;
  payment_plan_item_id: string | null;
  amount: number;
  currency: string;
  received_date: string;
  payment_method: string;
  description: string;
  reference_no: string;
  voided_at: string | null;
  void_reason: string;
  created_at: string;
}

export type ExpenseCategory =
  | "material" | "personnel" | "transport" | "accommodation"
  | "food" | "equipment" | "other";

export const EXPENSE_CATEGORY_LABELS: Record<ExpenseCategory, string> = {
  material: "Malzeme",
  personnel: "Personel",
  transport: "Nakliye",
  accommodation: "Konaklama",
  food: "Yemek",
  equipment: "Ekipman",
  other: "Diğer",
};

export interface Expense {
  id: string;
  category: ExpenseCategory;
  description: string;
  amount: number;
  currency: string;
  expense_date: string;
  supplier_name: string;
  invoice_no: string;
  notes: string;
  voided_at: string | null;
  void_reason: string;
  created_at: string;
  change_order_id?: string | null;
}

export type InvoiceStatus = "draft" | "issued" | "sent" | "paid" | "cancelled";

export const INVOICE_STATUS_LABELS: Record<InvoiceStatus, string> = {
  draft: "Taslak",
  issued: "Kesildi",
  sent: "Gönderildi",
  paid: "Ödendi",
  cancelled: "İptal",
};

export interface ProjectInvoice {
  id: string;
  invoice_no: string;
  invoice_type: "sales" | "purchase";
  invoice_date: string;
  due_date: string | null;
  amount: number;
  currency: string;
  status: InvoiceStatus;
  customer_name: string;
  notes: string;
  created_at: string;
}

export type SubcontractorStatus = "planned" | "active" | "completed" | "cancelled";

export const SUBCONTRACTOR_STATUS_LABELS: Record<SubcontractorStatus, string> = {
  planned: "Planlandı",
  active: "Devam Ediyor",
  completed: "Tamamlandı",
  cancelled: "İptal",
};

export interface Subcontractor {
  id: string;
  name: string;
  company_name: string;
  phone: string;
  email: string;
  work_description: string;
  contract_amount: number;
  paid_amount: number;
  remaining_amount: number;
  currency: string;
  start_date: string | null;
  end_date: string | null;
  status: SubcontractorStatus;
  notes: string;
  change_order_id?: string | null;
}

export interface SubcontractorPayment {
  id: string;
  subcontractor_id: string;
  amount: number;
  currency: string;
  paid_date: string;
  description: string;
  voided_at: string | null;
  void_reason: string;
  created_at: string;
}

export interface FinancialSummary {
  // Faz 8: ana sözleşme (ASLA değişmez) ile güncel proje bedeli (onaylı
  // ek işler/eksiltmelerle) arasındaki ayrım.
  base_contract_amount: number;
  approved_additions: number;
  approved_deductions: number;
  current_contract_value: number;
  pending_additions: number;
  pending_deductions: number;
  potential_contract_value: number;

  contract_amount: number;
  currency: string;
  planned_collections: number;
  collected_amount: number;
  remaining_receivable: number;
  over_collected: number;
  total_expenses: number;
  total_subcontractor_commitment: number;
  subcontractor_paid: number;
  subcontractor_remaining: number;
  issued_invoice_total: number;
  paid_invoice_total: number;
  realized_cost: number;
  committed_cost: number;
  realized_gross_profit: number;
  estimated_gross_profit: number;
  realized_margin_percent: number;
  estimated_margin_percent: number;
}

export interface ProjectEvent {
  id: string;
  event_type: string;
  user_id: string | null;
  metadata?: Record<string, unknown>;
  created_at: string;
}

// ---------- Faz 7: proje operasyon ----------

export interface ProjectMember {
  id: string;
  employee_id: string;
  employee_name: string;
  role_title: string;
  start_date: string | null;
  end_date: string | null;
  notes: string;
  is_active: boolean;
}

export type ScheduleStatus = "planned" | "active" | "completed" | "cancelled";

export const SCHEDULE_STATUS_LABELS: Record<ScheduleStatus, string> = {
  planned: "Planlandı",
  active: "Devam Ediyor",
  completed: "Tamamlandı",
  cancelled: "İptal",
};

export interface ScheduleItem {
  id: string;
  name: string;
  description: string;
  start_date: string | null;
  end_date: string | null;
  status: ScheduleStatus;
  sort_order: number;
  task_count: number;
  completed_task_count: number;
}

export type TaskStatus = "todo" | "in_progress" | "completed" | "cancelled";
export type TaskPriority = "low" | "normal" | "high" | "urgent";

export const TASK_STATUS_LABELS: Record<TaskStatus, string> = {
  todo: "Yapılacak",
  in_progress: "Devam Ediyor",
  completed: "Tamamlandı",
  cancelled: "İptal",
};

export const TASK_PRIORITY_LABELS: Record<TaskPriority, string> = {
  low: "Düşük",
  normal: "Normal",
  high: "Yüksek",
  urgent: "Acil",
};

export interface ProjectTask {
  id: string;
  schedule_item_id: string | null;
  title: string;
  description: string;
  assigned_employee_id: string | null;
  assigned_name: string;
  priority: TaskPriority;
  status: TaskStatus;
  due_date: string | null;
  completed_at: string | null;
  is_overdue: boolean;
}

export type FileCategory = "contract" | "drawing" | "invoice" | "report" | "other";

export const FILE_CATEGORY_LABELS: Record<FileCategory, string> = {
  contract: "Sözleşme",
  drawing: "Çizim",
  invoice: "Fatura",
  report: "Rapor",
  other: "Diğer",
};

export interface ProjectFile {
  id: string;
  original_name: string;
  mime_type: string;
  size_bytes: number;
  sha256: string;
  category: FileCategory;
  description: string;
  created_at: string;
}

export type PhotoStage = "before" | "progress" | "after";

export const PHOTO_STAGE_LABELS: Record<PhotoStage, string> = {
  before: "İş Öncesi",
  progress: "İlerleme",
  after: "İş Sonrası",
};

export interface ProjectPhoto {
  id: string;
  original_name: string;
  mime_type: string;
  size_bytes: number;
  stage: PhotoStage;
  description: string;
  taken_at: string | null;
  created_at: string;
}

export interface ProjectNote {
  id: string;
  content: string;
  created_by_name: string;
  created_at: string;
}

export interface OperationsSummary {
  active_member_count: number;
  total_task_count: number;
  open_task_count: number;
  overdue_task_count: number;
  completed_task_count: number;
  task_completion_ratio: number;
}

// ---------- Faz 8: ek işler / değişiklik emirleri ----------

export type ChangeOrderType = "addition" | "deduction";

export const CHANGE_ORDER_TYPE_LABELS: Record<ChangeOrderType, string> = {
  addition: "Ek İş",
  deduction: "Eksiltme",
};

export type ChangeOrderStatus = "draft" | "sent" | "approved" | "rejected" | "cancelled" | "superseded";

export const CHANGE_ORDER_STATUS_LABELS: Record<ChangeOrderStatus, string> = {
  draft: "Taslak",
  sent: "Gönderildi",
  approved: "Onaylandı",
  rejected: "Reddedildi",
  cancelled: "İptal",
  superseded: "Yerine Yeni Revizyon Oluşturuldu",
};

export interface ChangeOrderItem {
  id: string;
  product_id: string | null;
  description: string;
  quantity: number;
  unit: string;
  unit_price: number;
  line_total: number;
  sort_order: number;
  estimated_unit_cost?: number | null;
  estimated_cost?: number | null;
}

export interface ChangeOrderItemInput {
  product_id?: string | null;
  description: string;
  quantity: number;
  unit: string;
  unit_price: number;
  estimated_unit_cost?: number | null;
}

export interface ChangeOrderProfitability {
  revenue_effect: number;
  realized_cost: number;
  committed_cost: number;
  realized_profit: number;
  estimated_profit: number;
  realized_margin_percent: number;
  estimated_margin_percent: number;
}

// ChangeOrder, kimlik doğrulamalı (dahili) uçlardan gelir --
// internal_notes ve profitability (maliyet/kâr) taşır. Müşteri paylaşım
// sayfası bunun yerine PublicChangeOrder'ı kullanır (bkz. aşağısı).
export interface ChangeOrder {
  id: string;
  project_id: string;
  sequence_no: number;
  change_order_no: string;
  change_type: ChangeOrderType;
  title: string;
  description: string;
  status: ChangeOrderStatus;
  subtotal: number;
  vat_rate: number;
  vat_amount: number;
  grand_total: number;
  currency: string;
  internal_notes: string;
  customer_notes: string;
  created_by: string | null;
  created_at: string;
  updated_at: string;
  sent_at: string | null;
  responded_at: string | null;
  approved_at: string | null;
  rejected_at: string | null;
  cancelled_at: string | null;
  supersedes_change_order_id: string | null;
  active_share_token?: string | null;
  items?: ChangeOrderItem[];
  profitability?: ChangeOrderProfitability;
}

// PublicChangeOrder, müşteri paylaşım sayfasının aldığı TEK şekildir --
// maliyet/kâr/internal_notes ASLA içermez (bkz. backend
// publicChangeOrderResponse).
export interface PublicChangeOrder {
  change_order_no: string;
  project_no: string;
  project_name: string;
  customer_name: string;
  change_type: ChangeOrderType;
  title: string;
  description: string;
  status: ChangeOrderStatus;
  items: Array<{
    id: string;
    description: string;
    quantity: number;
    unit: string;
    unit_price: number;
    line_total: number;
  }>;
  subtotal: number;
  vat_rate: number;
  vat_amount: number;
  grand_total: number;
  currency: string;
  customer_notes: string;
  base_contract_amount: number;
  current_contract_value: number;
  projected_contract_value: number;
  can_respond: boolean;
}

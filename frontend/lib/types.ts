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

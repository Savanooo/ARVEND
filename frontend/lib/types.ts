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

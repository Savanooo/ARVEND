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

export interface Offer {
  id: string;
  offer_no: string;
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

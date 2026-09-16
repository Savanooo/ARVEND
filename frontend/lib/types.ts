export type Role = "admin" | "kullanici" | "super_admin";

export const ROLE_LABELS: Record<Role, string> = {
  admin: "Yönetici",
  kullanici: "Kullanıcı",
  super_admin: "Süper Admin",
};

export interface User {
  id: string;
  organization_id: string | null;
  organization_name: string;
  username: string;
  full_name: string;
  role: Role;
  is_active?: boolean;
  must_change_password: boolean;
  onboarding_completed: boolean;
  onboarding_step: string;
  // organization_role_*, RBAC/Project Membership sprint'inin ince-taneli
  // rolüdür (role'den TAMAMEN AYRI eksen) -- Süper Admin'de her zaman
  // boştur, önceki bir migration'ın henüz backfill etmediği nadir bir
  // durumda da boş olabilir.
  organization_role_code?: string;
  organization_role_name?: string;
  permissions?: string[];
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
  // Metraj Hesaplama entegrasyonu — serbest kalemlerde hepsi boş/null.
  unit?: string;
  section_label?: string | null;
  calc_category_id?: string | null;
  calc_snapshot?: CalcSnapshot | null;
}

// --- Metraj Hesaplama ---

export type CalcType = "area_based" | "perimeter_based" | "fixed";
export type RoundingType = "none" | "ceil" | "round";

export interface CalcGroup {
  id: string;
  slug: string;
  name: string;
  description: string;
  sort_order: number;
  is_active: boolean;
}

export interface CalcCategory {
  id: string;
  group_id: string;
  group_slug?: string;
  group_name?: string;
  slug: string;
  name: string;
  description: string;
  image_file_id?: string | null;
  sort_order: number;
  is_active: boolean;
}

export interface CalcGroupWithCategories {
  id: string;
  slug: string;
  name: string;
  categories: CalcCategory[];
}

export interface CalcRecipeItem {
  id: string;
  category_id: string;
  product_id?: string | null;
  material_name: string;
  unit: string;
  calculation_type: CalcType;
  quantity_per_m2: string;
  quantity_per_meter: string;
  fixed_quantity: string;
  waste_percent: string;
  rounding_type: RoundingType;
  min_quantity?: string | null;
  package_size?: string | null;
  reference_unit_price: string;
  group_name: string;
  sort_order: number;
  is_active: boolean;
  notes?: string | null;
}

// calc_snapshot alanları — hesap ANINDA teklif kalemine dondurulur;
// motor/reçete sonradan değişse bile bu değerler bir daha güncellenmez.
export interface CalcSnapshot {
  area: string;
  perimeter: string | null;
  pitch_deg: string | null;
  recipe_factor: string;
  waste_percent: string;
  rounding_type: RoundingType;
  price_at_calc: string;
  category_name?: string;
  group_name?: string;
}

export interface CalcWarning {
  item_id?: string;
  code: string;
  message: string;
}

export interface CalcResultItem {
  recipe_item_id: string;
  material_name: string;
  unit: string;
  quantity: string;
  product_id: string | null;
  unit_price: string;
  line_total: string;
  group_name: string;
  calculation_type: CalcType;
  factor: string;
  waste_percent: string;
  rounding_type: RoundingType;
}

export interface CalcRunResult {
  category: { id: string; slug: string; name: string };
  input: {
    footprint_area: string;
    effective_area: string;
    perimeter: string | null;
  };
  items: CalcResultItem[];
  total_cost: string;
  warnings: CalcWarning[];
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
  // Maliyet Kontrolü (Sprint 2) eşlemesi -- İKİSİ de opsiyonel, eski
  // masraflarda boştur (bkz. docs/cost-control.md).
  cost_code_id?: string | null;
  budget_line_id?: string | null;
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
  // Maliyet Kontrolü (Sprint 2) eşlemesi -- opsiyonel; taşeronun
  // budget_line_id'si YOKTUR (bkz. docs/cost-control.md).
  cost_code_id?: string | null;
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

// ---------------------------------------------------------------------------
// ARVEND — Super Admin + Firma/Mağaza Yönetimi + Onboarding
// ---------------------------------------------------------------------------

export type OrgStatus = "active" | "trial" | "suspended" | "cancelled";

export const ORG_STATUS_LABELS: Record<OrgStatus, string> = {
  active: "Aktif",
  trial: "Deneme",
  suspended: "Askıya Alınmış",
  cancelled: "İptal Edilmiş",
};

export type OnboardingStep = "company" | "billing" | "offers" | "finance" | "business" | "completed";

export const ONBOARDING_STEP_LABELS: Record<OnboardingStep, string> = {
  company: "Firma",
  billing: "Resmi / Fatura",
  offers: "Teklif",
  finance: "Finans",
  business: "İşletme",
  completed: "Tamamlandı",
};

// backend/internal/domain/onboarding.go: BusinessTypeWhitelist.
export const BUSINESS_TYPE_OPTIONS: Record<string, string> = {
  insaat_taahhut: "İnşaat / Taahhüt",
  tasarim_mimarlik: "Tasarım / Mimarlık",
  muhendislik_danismanlik: "Mühendislik / Danışmanlık",
  tedarik_montaj: "Tedarik / Montaj",
  diger: "Diğer",
};

export interface Organization {
  id: string;
  name: string;
  slug: string;
  is_active: boolean;
  status: OrgStatus;
  plan_code: string;
  trial_ends_at?: string | null;
  onboarding_completed: boolean;
  onboarding_completed_at?: string | null;
  onboarding_step: OnboardingStep;
  created_at: string;
  updated_at: string;
}

export interface Plan {
  code: string;
  name: string;
  is_active: boolean;
  max_users: number;
  max_projects: number;
  sort_order: number;
}

export interface OrganizationProfile {
  authorized_person: string;
  phone: string;
  email: string;
  website: string;
  logo_object_key: string;
  legal_name: string;
  tax_office: string;
  tax_number: string;
  invoice_address: string;
  city: string;
  district: string;
  country: string;
  business_type: string;
}

// iban_set: IBAN'ın kayıtlı olup olmadığı -- backend plaintext IBAN'ı ASLA
// döndürmez (bkz. internal/repository/pool.go ToDomainOrganizationCommercialSettings).
export interface OrganizationCommercialSettings {
  default_currency: string;
  default_vat_rate: number;
  offer_prefix: string;
  offer_validity_days: number;
  default_offer_footer: string;
  default_payment_terms: string;
  default_delivery_terms: string;
  bank_name: string;
  account_holder: string;
  iban_set: boolean;
  payment_due_days: number | null;
}

export interface OnboardingState {
  onboarding_completed: boolean;
  onboarding_step: OnboardingStep;
  profile: OrganizationProfile;
  commercial: OrganizationCommercialSettings;
}

// ---------------------------------------------------------------------------
// RBAC + Proje Erişimi (Sprint 1)
// ---------------------------------------------------------------------------

// OrgRoleCode, backend'in migration 0034'te seed ettiği 6 sistem rolü --
// "super_admin" ve "legacy_user" BİLİNÇLİ OLARAK burada bir seçenek
// DEĞİLDİR (legacy_user backend listesinde zaten hiç dönmez, super_admin
// organization_roles'ta hiç yoktur) -- web rol seçicisi bu union'ın
// DIŞINA çıkamaz.
export type OrgRoleCode = "owner" | "admin" | "project_manager" | "finance" | "field";

export const ORG_ROLE_LABELS: Record<OrgRoleCode, string> = {
  owner: "Sahip (Owner)",
  admin: "Yönetici",
  project_manager: "Proje Yöneticisi",
  finance: "Finans",
  field: "Saha",
};

export interface Permission {
  code: string;
  description: string;
  category: string;
}

export interface OrganizationRole {
  id: string;
  code: string;
  name: string;
  description: string;
  is_system: boolean;
  permissions: string[];
}

export type ProjectRole = "project_manager" | "member" | "viewer";

export const PROJECT_ROLE_LABELS: Record<ProjectRole, string> = {
  project_manager: "Proje Yöneticisi",
  member: "Üye",
  viewer: "Görüntüleyici",
};

// ProjectAccessUser, GET /projects/{id}/access'ten gelen tek bir satırdır
// -- mevcut ProjectMember (İK/puantaj roster'ı, employee_id'ye bağlı) İLE
// KARIŞTIRILMAMALI, bu bir UYGULAMA KULLANICISI erişim kaydıdır.
export interface ProjectAccessUser {
  user_id: string;
  username: string;
  full_name: string;
  user_is_active: boolean;
  project_role: ProjectRole;
  organization_role_code: string;
  organization_role_name: string;
}

// OrgUserOption, "Proje Erişimi" kullanıcı seçicisinin ihtiyaç duyduğu
// minimum alan kümesidir (User'ın tamamını değil).
export interface OrgUserOption {
  id: string;
  full_name: string;
  username: string;
  is_active?: boolean;
  organization_role_code?: string;
}

export interface UserProjectAssignment {
  project_id: string;
  project_no: string;
  project_name: string;
  project_role: ProjectRole;
}

export interface AuditEvent {
  id: string;
  actor_user_id: string | null;
  action: string;
  target_organization_id: string | null;
  target_user_id: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Sprint 2 — WBS + Maliyet Kodları + Proje Bütçesi + Maliyet Kontrolü
// (bkz. docs/cost-control.md). Bütçe/kalem/revizyon/taahhüt/tahmin akışları
// backend'de OTORİTERDİR — bu tipler yalnızca API yanıtlarının şeklidir,
// hiçbir hesap burada TEKRAR yapılmaz.
// ---------------------------------------------------------------------------

export interface OrganizationCostCode {
  id: string;
  code: string;
  name: string;
  description: string;
  category: string;
  is_active: boolean;
}

export interface WBSNode {
  id: string;
  parent_id?: string | null;
  code: string;
  name: string;
  sort_order: number;
  is_active: boolean;
}

export type BudgetStatus = "draft" | "baselined";

export const BUDGET_STATUS_LABELS: Record<BudgetStatus, string> = {
  draft: "Taslak",
  baselined: "Baseline Alındı",
};

export interface ProjectBudget {
  id: string;
  currency: string;
  status: BudgetStatus;
  version: number;
  baselined_at?: string | null;
}

export interface BudgetLine {
  id: string;
  wbs_node_id?: string | null;
  wbs_code?: string;
  wbs_name?: string;
  cost_code_id: string;
  cost_code_code?: string;
  cost_code_name?: string;
  description: string;
  quantity?: number | null;
  unit?: string;
  unit_cost?: number | null;
  original_amount: number;
  notes?: string;
}

export type AdjustmentStatus = "draft" | "approved" | "rejected";

export const ADJUSTMENT_STATUS_LABELS: Record<AdjustmentStatus, string> = {
  draft: "Taslak",
  approved: "Onaylandı",
  rejected: "Reddedildi",
};

export interface BudgetAdjustment {
  id: string;
  budget_line_id: string;
  amount: number;
  reason: string;
  status: AdjustmentStatus;
  approved_at?: string | null;
  created_at: string;
}

export type CommitmentStatus = "active" | "voided";

export const COMMITMENT_STATUS_LABELS: Record<CommitmentStatus, string> = {
  active: "Aktif",
  voided: "İptal Edildi",
};

// Commitment, bu sprintte YALNIZCA manuel taahhütleri temsil eder --
// source_type her zaman "manual"dır (bkz. docs/cost-control.md).
export interface Commitment {
  id: string;
  budget_line_id?: string | null;
  cost_code_id: string;
  cost_code_code?: string;
  cost_code_name?: string;
  source_type: "manual" | "purchase_order" | "subcontract";
  description: string;
  committed_amount: number;
  currency: string;
  status: CommitmentStatus;
  committed_at: string;
  voided_at?: string | null;
  void_reason?: string;
}

export interface CostForecast {
  budget_line_id: string;
  etc_amount: number;
  note: string;
  updated_at: string;
}

// CostControlLine, "Maliyet Kontrolü" kırılım tablosunun tek bir satırıdır.
// is_unbudgeted=true ise bu satırın bir bütçe kalemi YOKTUR — yalnızca o
// maliyet koduna doğrudan bağlı (bütçe kalemine bağlanmamış) taahhüt/gider
// vardır ("bütçe dışı harcama").
export interface CostControlLine {
  budget_line_id?: string | null;
  wbs_code?: string;
  wbs_name?: string;
  cost_code_id: string;
  cost_code_code: string;
  cost_code_name: string;
  description: string;
  original_budget: number;
  approved_adjustments: number;
  revised_budget: number;
  committed_cost: number;
  actual_cost: number;
  etc: number;
  eac: number;
  variance: number;
  is_unbudgeted: boolean;
}

// CostControlSummary — has_budget=false ise proje için HENÜZ bir bütçe
// oluşturulmamıştır (spec: "bütçesiz proje geçerli bir durumdur"); bu
// durumda contract_value dışındaki alanlar 0'dır.
export interface CostControlSummary {
  currency: string;
  contract_value: number;
  original_budget: number;
  approved_adjustments: number;
  revised_budget: number;
  committed_cost: number;
  actual_cost: number;
  etc: number;
  eac: number;
  variance: number;
  forecast_profit: number;
  forecast_margin_percent: number;
  has_budget: boolean;
}

export interface CostControlData {
  summary: CostControlSummary;
  lines: CostControlLine[];
}

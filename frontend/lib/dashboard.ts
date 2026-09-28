// Ana sayfa özeti (GET /api/v1/dashboard) -- web tarafının SAF mantığı:
// yanıt tipleri, modül/bant kayıt defteri, KPI seçimi, yerleşim, dikkat
// metinleri, bağlantı eşleyicileri ve Türkçe metinler. next/* ya da React
// içermez; hem Server/Client Component'ler hem node testleri
// (dashboard.test.mts, docs/dashboard/fixtures/*.json ile) içe aktarır.
//
// Temel kurallar (backend domain/dashboard.go ile aynı sözleşme):
//   - Yetkisi olmayan bölümün anahtarı "sections"ta HİÇ yoktur: kart
//     çizilmez (kilitli önizleme ya da sıfır YOK). Bölüm içindeki izne
//     bağlı alt blok null gelir, o alt blok gizlenir.
//   - İstemci para TOPLAMAZ, toplam YENİDEN HESAPLAMAZ: yalnızca biçimler
//     ve oran çizer. Farklı para birimleri asla toplanmaz; by_currency[0]
//     birincil para birimidir (sunucu sıralar), diğerleri "Diğer: …".
//   - Sunucu hiçbir zaman web yolu göndermez; nötr ref -> webHrefFor.
//   - İzin kontrolü istemcide YALNIZCA hızlı işlem düğmeleri, boş durum
//     CTA'ları ve iskelet tahmini içindir (asıl sınır backend'dedir).

import {
  formatCompactMoney,
  formatCount,
  formatMoney,
  formatPercent,
  formatSignedCompactMoney,
  MONTHS_LONG,
  MONTHS_SHORT,
  shiftDay,
} from "./format.ts";
import { canAccess } from "./permissions.ts";
import { sourceLabels } from "./price-sources.ts";
import type { Role } from "./types";

export const DASHBOARD_PATH = "/api/v1/dashboard";
export const PROJECT_OPTIONS_PATH = "/api/v1/dashboard/project-options";
export const NOTIFICATIONS_READ_ALL_PATH = "/api/v1/notifications/read-all";

// ---------------------------------------------------------------------------
// Yanıt tipleri (backend internal/domain/dashboard.go'nun birebir aynası)
// ---------------------------------------------------------------------------

export type ISODate = string; // "2026-09-28" (İstanbul takvim günü)
export type ISODateTime = string; // RFC3339, "+03:00"
export type Pct = number | null;

export interface MoneyAmount {
  currency: string;
  amount: number;
}
export interface CountAmount {
  count: number;
  amount: number;
}
export interface CountAmounts {
  count: number;
  amounts: MoneyAmount[];
}

export type RefKind =
  | "project"
  | "project_finance"
  | "project_cost"
  | "project_operations"
  | "offer"
  | "task"
  | "milestone"
  | "purchase_request"
  | "rfq"
  | "purchase_order"
  | "subcontract"
  | "progress_claim"
  | "subcontract_change_order"
  | "change_order"
  | "budget_adjustment"
  | "contract"
  | "payment_plan_item"
  | "invoice"
  | "customer"
  | "product"
  | "user"
  | "price_source";

export const REF_KINDS: readonly RefKind[] = [
  "project",
  "project_finance",
  "project_cost",
  "project_operations",
  "offer",
  "task",
  "milestone",
  "purchase_request",
  "rfq",
  "purchase_order",
  "subcontract",
  "progress_claim",
  "subcontract_change_order",
  "change_order",
  "budget_adjustment",
  "contract",
  "payment_plan_item",
  "invoice",
  "customer",
  "product",
  "user",
  "price_source",
];

export interface DashboardRef {
  // Bilinmeyen (sonradan eklenmiş) tür de gelebilir: webHrefFor null döner.
  kind: RefKind | (string & {});
  id: string;
  project_id: string | null;
  parent_id: string | null;
  action: "open" | "award" | "convert" | (string & {});
}

export type ModuleKey =
  | "finance"
  | "offers"
  | "change_orders"
  | "projects"
  | "tasks"
  | "operations"
  | "contracts"
  | "attendance"
  | "procurement"
  | "subcontracts"
  | "cost_control"
  | "customers"
  | "employees"
  | "products"
  | "users"
  | "calculations"
  | "suppliers"
  | "cost_codes";

export type SectionKey = ModuleKey | "notifications" | "activity";

export type Lane = "mine" | "watching";
export type Severity = "danger" | "action" | "info";

export interface AttentionRecord {
  ref: DashboardRef;
  label: string;
  project_name: string | null;
  amount: MoneyAmount | null;
  date: ISODate | null;
  days: number | null;
  pct: Pct;
}

export interface AttentionGroup {
  code: string;
  module: ModuleKey | (string & {});
  lane: Lane;
  severity: Severity;
  count: number;
  amounts: MoneyAmount[];
  oldest_days: number | null;
  items: AttentionRecord[];
}

export type UpcomingKind = "plan_item_due" | "offer_expiry" | "po_delivery" | "milestone_end" | "project_end" | "my_task_due";

export interface UpcomingItem {
  kind: UpcomingKind | (string & {});
  date: ISODate;
  ref: DashboardRef;
  title: string;
  project_name: string | null;
  amount: MoneyAmount | null;
}

export interface DashboardAgenda {
  groups: AttentionGroup[];
  upcoming: UpcomingItem[];
  mine_count: number;
  mine_danger_count: number;
  watching_count: number;
}

export interface DashboardViewer {
  user_id: string;
  organization_role_code: string;
  is_admin: boolean;
  all_projects: boolean;
  accessible_project_count: number;
}

export type OnboardingStepKey = "customer" | "catalog" | "employee" | "team" | "first_offer" | "convert";

export interface DashboardOnboarding {
  steps: { key: OnboardingStepKey | (string & {}); done: boolean; detail: string | null }[];
  done_count: number;
  total: number;
}

export interface ProjectRow {
  ref: DashboardRef;
  project_no: string;
  name: string;
  status: "planned" | "active" | "paused";
  customer_name: string;
  start_date: ISODate | null;
  end_date: ISODate | null;
  days_to_end: number | null;
  time_progress_pct: Pct;
  task_progress_pct: Pct;
  overdue_task_count: number | null;
  collection_pct: Pct;
  current_value: MoneyAmount | null;
  flags: string[];
}

export interface MyTask {
  ref: DashboardRef;
  title: string;
  project_name: string;
  due_date: ISODate | null;
  days_overdue: number | null;
  priority: "low" | "normal" | "high" | "urgent";
  status: "todo" | "in_progress";
}

export interface FinanceCurrency {
  currency: string;
  portfolio_value: number;
  collected_total: number;
  open_receivable: number;
  collection_pct: Pct;
  realized_cost: number;
  cash_balance: number;
  month: { collections: number; expenses: number; subcontract_payments: number; outflows: number; net_cash: number };
  overdue_plan: CountAmount;
  overdue_sales_invoices: CountAmount;
  trend_6m: { month: string; collections: number; outflows: number; net: number }[];
}

export interface DashboardSections {
  projects?: {
    counts: { planned: number; active: number; paused: number; completed: number; cancelled: number; total: number };
    past_end_date: number;
    ending_within_30d: number;
    top: ProjectRow[];
  };
  finance?: { by_currency: FinanceCurrency[] };
  change_orders?: {
    by_currency: { currency: string; awaiting_customer: CountAmount; draft: CountAmount; approved_net_this_month: number }[];
  };
  offers?: {
    total_active: number;
    by_currency: {
      currency: string;
      draft: CountAmount;
      awaiting_customer: CountAmount;
      accepted_90d: CountAmount;
      rejected_90d: CountAmount;
    }[];
    expiring_within_7d: number;
    expired_awaiting: number;
    viewed_by_customer_7d: number;
    accepted_not_converted: number;
    conversion_rate_90d_pct: Pct;
  };
  procurement?: {
    purchase_requests: { draft: number; submitted: number };
    rfqs: { issued: number; awaiting_award: number; past_due_no_quote: number };
    purchase_orders: { draft: number; approved_open: number; late_delivery: number };
    approved_this_month: { currency: string; count: number; amount: number }[];
  };
  subcontracts?: {
    active_count: number;
    by_currency: { currency: string; current_value: number; paid_to_date: number | null; paid_pct: Pct }[];
    claims: { submitted: CountAmounts; certified_unpaid: CountAmounts | null } | null;
    change_orders_submitted: CountAmounts;
  };
  cost_control?: {
    budgets: { none: number; draft: number; baselined: number; open_projects: number } | null;
    pending_adjustments: CountAmounts | null;
    committed_active: MoneyAmount[] | null;
    over_budget: { count: number; worst: { ref: DashboardRef; project_name: string; overrun_pct: number } | null } | null;
  };
  contracts?: {
    counts: { draft: number; active: number; completed: number; cancelled: number; terminated: number };
    active_projects_without_contract: number;
    past_planned_completion: number;
  };
  tasks?: {
    mine: { linked_employee: boolean; open: number; overdue: number; due_today: number; items: MyTask[] };
    team: { open: number; overdue: number; due_today: number; unassigned: number; completed_7d: number };
  };
  operations?: { active_crew: number; milestones: { due_7d: number; overdue: number }; photos_7d: number };
  attendance?: {
    date: ISODate;
    scope: "organization";
    active_employees: number;
    present: number;
    half_day: number;
    absent: number;
    on_leave: number;
    not_recorded: number;
    on_site: number;
    month_work_hours: number;
  };
  employees?: { active: number; inactive: number; with_user_account: number; new_this_month: number };
  customers?: { active: number; new_this_month: number; with_active_projects: number };
  products?: {
    total: number;
    by_source: { manual: number; ulas: number; demirprofil: number };
    price_changes_30d: {
      increased_count: number;
      decreased_count: number;
      products_increased: number;
      avg_increase_percent: Pct;
      max_increase: { ref: DashboardRef; product_name: string; change_percent: number } | null;
    };
    price_sources: {
      source: string;
      last_synced_at: ISODateTime | null;
      last_status: "never" | "success" | "failed" | (string & {});
      auto_sync: boolean;
      days_since_sync: number | null;
    }[];
  };
  calculations?: { groups: number; categories: number; used_in_offer_lines_30d: number | null; recipe_items_unlinked: number | null };
  suppliers?: { active: number; inactive: number; ordered_this_month: number | null };
  cost_codes?: { active: number; inactive: number; expenses_without_code_month: number | null };
  users?: {
    active: number;
    inactive: number;
    never_logged_in: number;
    restricted_without_project: number;
    without_employee_link: number;
    by_role: { code: string; name: string; count: number }[];
    with_personal_overrides: number | null;
  };
  notifications?: {
    unread: number;
    latest: {
      id: string;
      type: string;
      title: string;
      body: string;
      action_target: string | null;
      created_at: ISODateTime;
      read_at: ISODateTime | null;
    }[];
  };
  activity?: {
    items: {
      source: "project" | "offer" | (string & {});
      event_type: string;
      ref: DashboardRef;
      project_no: string | null;
      project_name: string | null;
      offer_no: string | null;
      user_name: string | null;
      created_at: ISODateTime;
    }[];
  };
}

export interface DashboardResponse {
  generated_at: ISODateTime;
  today: ISODate;
  timezone: string;
  is_workday: boolean;
  period: { month_start: ISODate; next_month_start: ISODate; upcoming_end: ISODate };
  primary_currency: string;
  viewer: DashboardViewer;
  onboarding: DashboardOnboarding | null;
  agenda: DashboardAgenda;
  sections: DashboardSections;
  section_errors: Partial<Record<SectionKey, string>>;
}

// GET /api/v1/dashboard/project-options satırı -- tutar alanı YOK (hızlı
// işlem proje seçicisi GET /projects'i kullanmaz, o uç tutar döner).
export interface ProjectOption {
  id: string;
  project_no: string;
  name: string;
  customer_name: string;
  currency: string;
  status: string;
}

// --- Yanıt biçim kontrolü ---------------------------------------------------
// Kartlar alanlara doğrudan erişir (s.by_currency[0].month ...). Sürüm
// kayması ya da yarım bir bölüm, akış içinde render hatasına (HANDOFF §7:
// HTTP 200 ile sessizce bozulan sayfa) dönüşmesin diye her bölümün
// kartların eriştiği dizi/nesne alanları burada denetlenir; biçimi bozuk
// bölüm atılır ve section_errors'a yazılır (kart "yüklenemedi" gövdesiyle
// çizilir, diğer kartlar etkilenmez).

type Rec = Record<string, unknown>;
const isObj = (v: unknown): v is Rec => typeof v === "object" && v !== null && !Array.isArray(v);
const isArr = (v: unknown, each: (x: unknown) => boolean = isObj): boolean => Array.isArray(v) && v.every(each);
const objs = (v: Rec, ...keys: string[]) => keys.every((k) => isObj(v[k]));
const withRef = (v: unknown) => isObj(v) && isObj(v.ref);
const countAmounts = (v: unknown) => isObj(v) && isArr(v.amounts);
const nullOr = (check: (v: unknown) => boolean) => (v: unknown) => v === null || check(v);

const SECTION_SHAPES: Record<SectionKey, (s: Rec) => boolean> = {
  projects: (s) => objs(s, "counts") && isArr(s.top, withRef),
  finance: (s) =>
    isArr(s.by_currency, (r) => isObj(r) && objs(r, "month", "overdue_plan", "overdue_sales_invoices") && isArr(r.trend_6m)),
  change_orders: (s) => isArr(s.by_currency, (r) => isObj(r) && objs(r, "awaiting_customer", "draft")),
  offers: (s) =>
    isArr(s.by_currency, (r) => isObj(r) && objs(r, "draft", "awaiting_customer", "accepted_90d", "rejected_90d")),
  procurement: (s) => objs(s, "purchase_requests", "rfqs", "purchase_orders") && isArr(s.approved_this_month),
  subcontracts: (s) =>
    isArr(s.by_currency) &&
    countAmounts(s.change_orders_submitted) &&
    nullOr((c) => isObj(c) && countAmounts(c.submitted) && nullOr(countAmounts)(c.certified_unpaid))(s.claims),
  cost_control: (s) =>
    nullOr(isObj)(s.budgets) &&
    nullOr(countAmounts)(s.pending_adjustments) &&
    nullOr((v) => isArr(v))(s.committed_active) &&
    nullOr((o) => isObj(o) && nullOr(withRef)(o.worst))(s.over_budget),
  contracts: (s) => objs(s, "counts"),
  tasks: (s) => isObj(s.mine) && isArr(s.mine.items, withRef) && isObj(s.team),
  operations: (s) => objs(s, "milestones"),
  attendance: () => true,
  employees: () => true,
  customers: () => true,
  products: (s) =>
    objs(s, "by_source", "price_changes_30d") &&
    nullOr(withRef)((s.price_changes_30d as Rec).max_increase) &&
    isArr(s.price_sources),
  calculations: () => true,
  suppliers: () => true,
  cost_codes: () => true,
  users: (s) => isArr(s.by_role),
  notifications: (s) => isArr(s.latest),
  activity: (s) => isArr(s.items, withRef),
};

const isAttentionGroup = (g: unknown) =>
  isObj(g) && typeof g.code === "string" && typeof g.count === "number" && isArr(g.amounts) && isArr(g.items, withRef);
const isUpcomingItem = (u: unknown) => withRef(u) && typeof (u as Rec).date === "string";

/**
 * Sunucu yanıtını kabul eder ve biçimini denetler: temel alanlar yoksa null
 * (sayfa "Özet yüklenemedi" gösterir, çökmez); biçimi bozuk bölüm atılıp
 * section_errors'a yazılır; bozuk dikkat grubu/yaklaşan satırı atlanır.
 */
export function normalizeDashboard(raw: unknown): DashboardResponse | null {
  if (!isObj(raw)) return null;
  const d = raw as Partial<DashboardResponse> & Rec;
  if (typeof d.today !== "string" || typeof d.generated_at !== "string") return null;
  if (!isObj(d.viewer) || !isObj(d.sections)) return null;
  if (!isObj(d.period) || typeof (d.period as Rec).month_start !== "string") return null;

  const sectionErrors: Partial<Record<SectionKey, string>> = isObj(d.section_errors) ? { ...d.section_errors } : {};
  const sections: Rec = { ...(d.sections as Rec) };
  for (const key of Object.keys(SECTION_SHAPES) as SectionKey[]) {
    if (!(key in sections)) continue;
    const s = sections[key];
    if (!isObj(s) || !SECTION_SHAPES[key](s)) {
      delete sections[key];
      sectionErrors[key] = sectionErrors[key] || "malformed";
    }
  }

  const agenda: Rec = isObj(d.agenda) ? d.agenda : {};
  const onboarding = isObj(d.onboarding) && isArr(d.onboarding.steps) ? (d.onboarding as unknown as DashboardOnboarding) : null;
  const num = (v: unknown) => (typeof v === "number" ? v : 0);
  return {
    ...(d as DashboardResponse),
    sections: sections as DashboardSections,
    onboarding,
    primary_currency: d.primary_currency || "TRY",
    agenda: {
      groups: Array.isArray(agenda.groups) ? (agenda.groups.filter(isAttentionGroup) as AttentionGroup[]) : [],
      upcoming: Array.isArray(agenda.upcoming) ? (agenda.upcoming.filter(isUpcomingItem) as UpcomingItem[]) : [],
      mine_count: num(agenda.mine_count),
      mine_danger_count: num(agenda.mine_danger_count),
      watching_count: num(agenda.watching_count),
    },
    section_errors: sectionErrors,
  };
}

// ---------------------------------------------------------------------------
// Modül kayıt defteri ve bantlar (sabit sıra; veriye göre ASLA değişmez)
// ---------------------------------------------------------------------------

export type BandKey = "cash_sales" | "project_field" | "supply_cost" | "records";

export interface ModuleMeta {
  key: ModuleKey;
  title: string;
  // Kartın başlık/"Aç" bağlantısı (spec §2 "Web link").
  href: string;
  band: BandKey;
  compact: boolean;
  // Kurulum modunda tek "Proje modülleri" kartına katlanan proje bağlı kartlar.
  projectBound: boolean;
}

const ACTIVE_PROJECTS_HREF = "/projeler?status=active";

export const MODULES: Record<ModuleKey, ModuleMeta> = {
  finance: { key: "finance", title: "Proje Finansı", href: ACTIVE_PROJECTS_HREF, band: "cash_sales", compact: false, projectBound: true },
  offers: { key: "offers", title: "Teklifler", href: "/teklifler", band: "cash_sales", compact: false, projectBound: false },
  change_orders: { key: "change_orders", title: "Ek İşler", href: ACTIVE_PROJECTS_HREF, band: "cash_sales", compact: false, projectBound: true },
  projects: { key: "projects", title: "Projeler", href: ACTIVE_PROJECTS_HREF, band: "project_field", compact: false, projectBound: true },
  tasks: { key: "tasks", title: "Görevler", href: ACTIVE_PROJECTS_HREF, band: "project_field", compact: false, projectBound: true },
  operations: { key: "operations", title: "Şantiye", href: ACTIVE_PROJECTS_HREF, band: "project_field", compact: false, projectBound: true },
  contracts: { key: "contracts", title: "Sözleşmeler", href: ACTIVE_PROJECTS_HREF, band: "project_field", compact: false, projectBound: true },
  attendance: { key: "attendance", title: "Mesai / Puantaj", href: "/mesai", band: "project_field", compact: false, projectBound: false },
  procurement: { key: "procurement", title: "Satın Alma", href: ACTIVE_PROJECTS_HREF, band: "supply_cost", compact: false, projectBound: true },
  subcontracts: { key: "subcontracts", title: "Taşeron", href: ACTIVE_PROJECTS_HREF, band: "supply_cost", compact: false, projectBound: true },
  cost_control: { key: "cost_control", title: "Bütçe & Maliyet", href: ACTIVE_PROJECTS_HREF, band: "supply_cost", compact: false, projectBound: true },
  customers: { key: "customers", title: "Müşteriler", href: "/musteriler", band: "records", compact: false, projectBound: false },
  employees: { key: "employees", title: "Personel", href: "/admin/personel", band: "records", compact: false, projectBound: false },
  products: { key: "products", title: "Ürünler & Zam", href: "/admin/urunler/zamlar?period=30", band: "records", compact: false, projectBound: false },
  users: { key: "users", title: "Ekip", href: "/admin/kullanicilar", band: "records", compact: false, projectBound: false },
  calculations: { key: "calculations", title: "Metraj", href: "/admin/metraj-hesaplama", band: "records", compact: true, projectBound: false },
  suppliers: { key: "suppliers", title: "Tedarikçiler", href: "/admin/tedarikciler", band: "records", compact: true, projectBound: false },
  cost_codes: { key: "cost_codes", title: "Maliyet Kodları", href: "/admin/maliyet-kodlari", band: "records", compact: true, projectBound: false },
};

export interface BandMeta {
  key: BandKey;
  title: string;
  standard: readonly ModuleKey[];
  compact: readonly ModuleKey[];
}

// Başlıklar cümle düzeninde; web büyük harfi CSS ile verir (<html lang="tr">
// "i" -> "İ"yi doğru çevirir).
export const BANDS: readonly BandMeta[] = [
  { key: "cash_sales", title: "Nakit & Satış", standard: ["finance", "offers", "change_orders"], compact: [] },
  {
    key: "project_field",
    title: "Proje & Saha",
    standard: ["projects", "tasks", "operations", "contracts", "attendance"],
    compact: [],
  },
  { key: "supply_cost", title: "Tedarik & Maliyet", standard: ["procurement", "subcontracts", "cost_control"], compact: [] },
  {
    key: "records",
    title: "Firma kayıtları",
    standard: ["customers", "employees", "products", "users"],
    compact: ["calculations", "suppliers", "cost_codes"],
  },
];

export const MODULE_KEYS: readonly ModuleKey[] = BANDS.flatMap((b) => [...b.standard, ...b.compact]);
const STANDARD_ORDER: readonly ModuleKey[] = BANDS.flatMap((b) => b.standard);
const COMPACT_ORDER: readonly ModuleKey[] = BANDS.flatMap((b) => b.compact);

// Bu kadar ya da daha az standart kart görünüyorsa bant başlıkları kalkar,
// tek "Bölümler" ızgarası kullanılır (saha/proje yöneticisi/yeni firma).
export const DENSITY_MAX_STANDARD = 5;

export function isModuleKey(key: string): key is ModuleKey {
  return Object.prototype.hasOwnProperty.call(MODULES, key);
}

// ---------------------------------------------------------------------------
// Bölüm kapıları (iskelet tahmini) -- backend dashboardRegistry ile AYNI
// ---------------------------------------------------------------------------

export interface DashboardUser {
  role: Role;
  permissions?: readonly string[];
}

// Fail-closed: izin kümesi yoksa bölüm yok sayılır. users için canAccess
// kaba rol admin şartını da uygular (organization.users.read Yönetici'ye
// kilitli).
const SECTION_GATES: readonly (readonly [SectionKey, (u: DashboardUser) => boolean])[] = [
  ["projects", (u) => canAccess(u, "projects.read")],
  ["finance", (u) => canAccess(u, "projects.finance.read")],
  ["change_orders", (u) => canAccess(u, "projects.finance.read")],
  ["offers", (u) => canAccess(u, "offers.read")],
  ["procurement", (u) => canAccess(u, "projects.procurement.read")],
  ["subcontracts", (u) => canAccess(u, "projects.subcontracts.read")],
  ["cost_control", (u) => canAccess(u, "projects.budget.read") || canAccess(u, "projects.cost_control.read")],
  ["contracts", (u) => canAccess(u, "projects.contracts.read")],
  ["tasks", (u) => canAccess(u, "projects.tasks.read")],
  ["operations", (u) => canAccess(u, "projects.operations.read")],
  ["attendance", (u) => canAccess(u, "attendance.read")],
  ["employees", (u) => canAccess(u, "employees.read")],
  ["customers", (u) => canAccess(u, "customers.read")],
  ["products", (u) => canAccess(u, "products.read")],
  ["calculations", (u) => canAccess(u, "calculations.read")],
  ["suppliers", (u) => canAccess(u, "organization.suppliers.read")],
  ["cost_codes", (u) => canAccess(u, "organization.cost_codes.read")],
  ["users", (u) => canAccess(u, "organization.users.read")],
  ["notifications", (u) => canAccess(u, "notifications.read")],
  ["activity", () => true],
];

/** Kullanıcının izinlerinden sunucunun döndüreceği bölüm anahtarlarının tahmini (iskelet için). */
export function predictSections(user: DashboardUser): SectionKey[] {
  return SECTION_GATES.filter(([, gate]) => gate(user)).map(([key]) => key);
}

// ---------------------------------------------------------------------------
// Bölüm görünürlüğü ve yerleşim
// ---------------------------------------------------------------------------

export function sectionFailed(data: Pick<DashboardResponse, "section_errors">, key: SectionKey): boolean {
  return Boolean(data.section_errors?.[key]);
}

// Dikkat ya da Yaklaşan satırı üreten modüller (spec §3.1/§3.2; backend
// domain.AttentionRules modülleri). Yalnızca bunlardan biri hesaplanamazsa
// Dikkat listesi eksik olabilir; bildirim, hareket, müşteri, personel,
// metraj, tedarikçi ve maliyet kodu hatası listeyi etkilemez.
export const ATTENTION_MODULES: readonly ModuleKey[] = [
  "finance",
  "offers",
  "change_orders",
  "projects",
  "tasks",
  "operations",
  "contracts",
  "attendance",
  "procurement",
  "subcontracts",
  "cost_control",
  "products",
  "users",
];

/** Dikkat "liste eksik olabilir" notu: dikkat üreten bir bölüm hesaplanamadıysa. */
export function attentionPartial(data: Pick<DashboardResponse, "section_errors">): boolean {
  return ATTENTION_MODULES.some((key) => sectionFailed(data, key));
}

/**
 * Kartı çizilecek modüller (sabit sırada): bölüm anahtarı gelmiş YA DA
 * bölüm hesaplanamamış (section_errors -- kart başlığıyla birlikte hata
 * gövdesi gösterir). Kurulum modunda proje bağlı kartlar yer tutucuya
 * katlanır.
 */
export function visibleModules(data: Pick<DashboardResponse, "sections" | "section_errors">, onboardingActive: boolean): ModuleKey[] {
  return MODULE_KEYS.filter((key) => {
    if (onboardingActive && MODULES[key].projectBound) return false;
    return data.sections[key] !== undefined || sectionFailed(data, key);
  });
}

export interface LayoutBand {
  key: BandKey | "all";
  title: string;
  // Kurulum modunda "Proje modülleri" yer tutucusu ızgaranın başında tam genişlikte.
  placeholder: boolean;
  standard: ModuleKey[];
  compact: ModuleKey[];
}

export interface DashboardLayout {
  density: boolean;
  standardCount: number;
  bands: LayoutBand[];
}

export const DENSITY_BAND_TITLE = "Bölümler";

/** Görünen modülleri bantlara (ya da yoğun modda tek "Bölümler" ızgarasına) yerleştirir. */
export function layoutBands(modules: readonly ModuleKey[], onboardingActive: boolean): DashboardLayout {
  const set = new Set(modules);
  const standard = STANDARD_ORDER.filter((k) => set.has(k) && !(onboardingActive && MODULES[k].projectBound));
  const compact = COMPACT_ORDER.filter((k) => set.has(k));
  if (onboardingActive || standard.length <= DENSITY_MAX_STANDARD) {
    const empty = standard.length === 0 && compact.length === 0 && !onboardingActive;
    return {
      density: true,
      standardCount: standard.length,
      bands: empty ? [] : [{ key: "all", title: DENSITY_BAND_TITLE, placeholder: onboardingActive, standard, compact }],
    };
  }
  const bands = BANDS.map((b) => ({
    key: b.key,
    title: b.title,
    placeholder: false,
    standard: b.standard.filter((k) => set.has(k)),
    compact: b.compact.filter((k) => set.has(k)),
  })).filter((b) => b.standard.length + b.compact.length > 0);
  return { density: false, standardCount: standard.length, bands };
}

/**
 * Standart kart ızgarası (12 sütun) -- son satırda boşluk kalmaz: T2'de
 * (@2xl, 2 sütun) tek kalan kart tam genişlik; T3'te (@4xl, 3 sütun) tek
 * kalan tam genişlik (geniş mod), iki kalan 6/6. Sınıflar statik
 * literaldir (Tailwind bu dosyayı tarar).
 */
export function spanClass(i: number, n: number): string {
  const t2 = n % 2 === 1 && i === n - 1 ? "@2xl:col-span-12" : "@2xl:col-span-6";
  return `col-span-12 ${t2} ${threeColumnSpan(i, n)}`;
}

/** Kompakt kart ızgarası: aynı kural, 2 sütuna @xl'de geçer. */
export function compactSpanClass(i: number, n: number): string {
  const t2 = n % 2 === 1 && i === n - 1 ? "@xl:col-span-12" : "@xl:col-span-6";
  return `col-span-12 ${t2} ${threeColumnSpan(i, n)}`;
}

function threeColumnSpan(i: number, n: number): string {
  const r = n % 3;
  if (r === 1 && i === n - 1) return "@4xl:col-span-12";
  if (r === 2 && i >= n - 2) return "@4xl:col-span-6";
  return "@4xl:col-span-4";
}

/** KPI satırı ızgarası; n < 2 ise satır çizilmez (""). */
export function kpiGridClass(n: number): string {
  if (n >= 4) return "grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @4xl:grid-cols-4 @4xl:gap-4";
  if (n === 3) {
    return "grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @2xl:grid-cols-3 @4xl:gap-4 @min-[22rem]:[&>*:last-child]:col-span-2 @2xl:[&>*:last-child]:col-span-1";
  }
  if (n === 2) return "grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @4xl:gap-4";
  return "";
}

export type SecondaryPanel = "cash" | "my_tasks" | null;

/** Dikkat'in yanındaki panel: finans varsa Nakit Akışı, yoksa personele bağlıysa Görevlerim. */
export function secondaryPanel(data: Pick<DashboardResponse, "sections">): SecondaryPanel {
  if (data.sections.finance) return "cash";
  if (data.sections.tasks?.mine.linked_employee) return "my_tasks";
  return null;
}

// ---------------------------------------------------------------------------
// Nabız (KPI) -- sıradaki ilk 4 uygun aday; 2'den azsa satır gizlenir
// ---------------------------------------------------------------------------

export type KpiKey =
  | "receivable"
  | "net_cash"
  | "pipeline"
  | "cash_balance"
  | "active_projects"
  | "my_tasks"
  | "team_overdue"
  | "on_site"
  | "unread";

export const KPI_ORDER: readonly KpiKey[] = [
  "receivable",
  "net_cash",
  "pipeline",
  "cash_balance",
  "active_projects",
  "my_tasks",
  "team_overdue",
  "on_site",
  "unread",
];

export const KPI_MAX = 4;
export const KPI_MIN = 2;

function kpiAvailable(s: DashboardSections, key: KpiKey): boolean {
  switch (key) {
    case "receivable":
    case "net_cash":
    case "cash_balance":
      return (s.finance?.by_currency.length ?? 0) > 0;
    case "pipeline":
      return (s.offers?.by_currency.length ?? 0) > 0;
    case "active_projects":
      return s.projects !== undefined;
    case "my_tasks":
      return s.tasks?.mine.linked_employee === true;
    case "team_overdue":
      return s.tasks !== undefined;
    case "on_site":
      return s.attendance !== undefined;
    case "unread":
      return s.notifications !== undefined;
  }
}

/** Gösterilecek KPI anahtarları (bölümü hesaplanamayan aday düşer, sıradaki gelir). */
export function pickKpis(data: Pick<DashboardResponse, "sections">): KpiKey[] {
  const picked = KPI_ORDER.filter((k) => kpiAvailable(data.sections, k)).slice(0, KPI_MAX);
  return picked.length >= KPI_MIN ? picked : [];
}

/** İskelet için: izinlerden tahmin edilen KPI kutusu sayısı. */
export function predictKpiCount(sections: readonly SectionKey[]): number {
  const s = new Set(sections);
  const need: Record<KpiKey, SectionKey> = {
    receivable: "finance",
    net_cash: "finance",
    pipeline: "offers",
    cash_balance: "finance",
    active_projects: "projects",
    my_tasks: "tasks",
    team_overdue: "tasks",
    on_site: "attendance",
    unread: "notifications",
  };
  const n = Math.min(KPI_MAX, KPI_ORDER.filter((k) => s.has(need[k])).length);
  return n >= KPI_MIN ? n : 0;
}

export interface KpiTile {
  key: KpiKey;
  label: string;
  // Kısa değer (D5) ve tam değer (title/ekran okuyucu).
  value: string;
  valueFull: string;
  // Yalnızca işaretli değerlerde (ve Ekipte geciken görev > 0) renk.
  tone: "success" | "danger" | null;
  sub: string[];
  // Birden çok para biriminde: "Diğer: 45.000 $" (düz metin).
  other: string | null;
  href: string | null;
  progress: { pct: number; label: string } | null;
}

// Tam birime yuvarlanınca sıfır kalan para birimleri gösterilmez ("Diğer:
// 0 $" bilgi taşımaz); mobil kpi_grid.dart/module_cards.dart _others ile aynı kural.
function othersLine<T extends { currency: string }>(rows: readonly T[], pick: (r: T) => number, signed = false): string | null {
  const rest = rows.slice(1).filter((r) => Math.abs(pick(r)) >= 0.5);
  if (rest.length === 0) return null;
  const values = rest.map((r) => (signed ? formatSignedCompactMoney(pick(r), r.currency) : formatCompactMoney(pick(r), r.currency)));
  return COPY.other(values.join(" · "));
}

function signTone(value: number): "success" | "danger" | null {
  const rounded = Math.round(value);
  return rounded > 0 ? "success" : rounded < 0 ? "danger" : null;
}

/** Bir KPI kutusunun görünür modeli (tüm sayılar sunucudan; burada yalnızca biçim). */
export function kpiTile(data: Pick<DashboardResponse, "sections" | "primary_currency">, key: KpiKey): KpiTile {
  const s = data.sections;
  const base: Pick<KpiTile, "key" | "tone" | "sub" | "other" | "progress"> = { key, tone: null, sub: [], other: null, progress: null };
  switch (key) {
    case "receivable": {
      const rows = s.finance?.by_currency ?? [];
      const f = rows[0];
      const pct = f?.collection_pct ?? null;
      return {
        ...base,
        label: "Açık alacak",
        value: formatCompactMoney(f?.open_receivable ?? 0, f?.currency),
        valueFull: formatMoney(f?.open_receivable ?? 0, f?.currency),
        sub: pct === null ? [] : [`${formatPercent(pct)} tahsil edildi`],
        other: othersLine(rows, (r) => r.open_receivable),
        href: ACTIVE_PROJECTS_HREF,
        progress: pct === null ? null : { pct, label: `Tahsilat yüzde ${formatPercentNumber(pct)}` },
      };
    }
    case "net_cash": {
      const rows = s.finance?.by_currency ?? [];
      const f = rows[0];
      const net = f?.month.net_cash ?? 0;
      return {
        ...base,
        label: "Bu ay net nakit",
        value: formatSignedCompactMoney(net, f?.currency),
        valueFull: formatSignedMoneyFull(net, f?.currency),
        tone: signTone(net),
        sub: [
          `Giriş ${formatCompactMoney(f?.month.collections ?? 0, f?.currency)}`,
          `Çıkış ${formatCompactMoney(f?.month.outflows ?? 0, f?.currency)}`,
        ],
        other: othersLine(rows, (r) => r.month.net_cash, true),
        href: "#nakit-akisi",
      };
    }
    case "pipeline": {
      const rows = s.offers?.by_currency ?? [];
      const o = rows[0];
      const rate = s.offers?.conversion_rate_90d_pct ?? null;
      const sub = [`${formatCount(o?.awaiting_customer.count ?? 0)} teklif yanıt bekliyor`];
      if (rate !== null) sub.push(`Kabul oranı ${formatPercent(rate)} · 90 gün`);
      return {
        ...base,
        label: "Teklif hattı",
        value: formatCompactMoney(o?.awaiting_customer.amount ?? 0, o?.currency),
        valueFull: formatMoney(o?.awaiting_customer.amount ?? 0, o?.currency),
        sub,
        other: othersLine(rows, (r) => r.awaiting_customer.amount),
        href: "/teklifler",
      };
    }
    case "cash_balance": {
      const rows = s.finance?.by_currency ?? [];
      const f = rows[0];
      const bal = f?.cash_balance ?? 0;
      return {
        ...base,
        label: "Proje nakit dengesi",
        value: formatSignedCompactMoney(bal, f?.currency),
        valueFull: formatSignedMoneyFull(bal, f?.currency),
        tone: signTone(bal),
        // İki satır (§5.5 çizimi gibi): dar kutuda tek satır kırpılıp
        // harcama değeri kayboluyordu.
        sub: [
          `Tahsilat ${formatCompactMoney(f?.collected_total ?? 0, f?.currency)}`,
          `Harcama ${formatCompactMoney(f?.realized_cost ?? 0, f?.currency)}`,
        ],
        other: othersLine(rows, (r) => r.cash_balance, true),
        href: ACTIVE_PROJECTS_HREF,
      };
    }
    case "active_projects": {
      const c = s.projects?.counts;
      const value = formatCount(c?.active ?? 0);
      return {
        ...base,
        label: "Aktif proje",
        value,
        valueFull: value,
        sub: [`${formatCount(c?.planned ?? 0)} planlanan · ${formatCount(c?.paused ?? 0)} beklemede`],
        href: ACTIVE_PROJECTS_HREF,
      };
    }
    case "my_tasks": {
      const m = s.tasks?.mine;
      const value = formatCount(m?.open ?? 0);
      return {
        ...base,
        label: "Açık görevim",
        value,
        valueFull: value,
        sub: [`${formatCount(m?.overdue ?? 0)} gecikmiş · ${formatCount(m?.due_today ?? 0)} bugün`],
        href: secondaryPanel(data) === "my_tasks" ? "#gorevlerim" : "#modul-tasks",
      };
    }
    case "team_overdue": {
      const t = s.tasks?.team;
      const value = formatCount(t?.overdue ?? 0);
      return {
        ...base,
        label: "Ekipte geciken görev",
        value,
        valueFull: value,
        tone: (t?.overdue ?? 0) > 0 ? "danger" : null,
        sub: [`${formatCount(t?.unassigned ?? 0)} görev atanmamış`],
        href: "#modul-tasks",
      };
    }
    case "on_site": {
      const a = s.attendance;
      const value = `${formatCount(a?.on_site ?? 0)} / ${formatCount(a?.active_employees ?? 0)}`;
      return {
        ...base,
        label: "Bugün sahada",
        value,
        valueFull: value,
        sub: [`Firma geneli · ${formatCount(a?.not_recorded ?? 0)} kişi girilmedi`],
        href: "/mesai",
      };
    }
    case "unread": {
      const n = s.notifications;
      const value = formatCount(n?.unread ?? 0);
      const latest = n?.latest[0]?.title;
      return {
        ...base,
        label: "Okunmamış bildirim",
        value,
        valueFull: value,
        sub: latest ? [latest] : [],
        href: "#bildirimler",
      };
    }
  }
}

function formatSignedMoneyFull(value: number, currency = "TRY"): string {
  const sign = value > 0 ? "+" : value < 0 ? "-" : "";
  return `${sign}${formatMoney(Math.abs(value), currency)}`;
}

/** Ekran okuyucu metni için yüzde sayısı: 59.2 -> "59,2". */
export function formatPercentNumber(value: number): string {
  return formatPercent(value).slice(1);
}

// ---------------------------------------------------------------------------
// Özet cümlesi ve kapsam satırı
// ---------------------------------------------------------------------------

export function summarySentence(agenda: Pick<DashboardAgenda, "mine_count" | "mine_danger_count" | "watching_count">): string {
  if (agenda.mine_count > 0) {
    const urgent = agenda.mine_danger_count > 0 ? `; ${agenda.mine_danger_count} tanesi acil.` : ".";
    return `Bugün ${agenda.mine_count} iş senin sıranda${urgent}`;
  }
  if (agenda.watching_count > 0) return `Senin sıranda iş yok; ${agenda.watching_count} konu takipte.`;
  return "Bugün seni bekleyen bir iş yok.";
}

/** Üyelikle sınırlı izleyicide kapsam satırı; tüm projeleri görende null. */
export function scopeLine(viewer: Pick<DashboardViewer, "all_projects" | "accessible_project_count">): string | null {
  if (viewer.all_projects) return null;
  if (viewer.accessible_project_count === 0) {
    return "Henüz bir projeye eklenmedin; yöneticin seni eklediğinde proje verileri burada görünür.";
  }
  return `Üyesi olduğun ${formatCount(viewer.accessible_project_count)} projenin verileri gösteriliyor.`;
}

// ---------------------------------------------------------------------------
// Dikkat Gerektirenler
// ---------------------------------------------------------------------------

/** Kartın dikkat grupları (sunucunun sıralamasıyla). */
export function moduleAttention(data: Pick<DashboardResponse, "agenda">, key: ModuleKey): AttentionGroup[] {
  return data.agenda.groups.filter((g) => g.module === key);
}

export interface AttentionChip {
  tone: "danger" | "gold" | "info";
  label: string;
}

/** Kart başlığı rozeti: tehlike > aksiyon > bilgi; grup yoksa null. */
export function attentionChip(groups: readonly Pick<AttentionGroup, "severity" | "count">[]): AttentionChip | null {
  const sum = (sev: Severity) => groups.filter((g) => g.severity === sev).reduce((n, g) => n + g.count, 0);
  if (groups.some((g) => g.severity === "danger")) return { tone: "danger", label: `${formatCount(sum("danger"))} uyarı` };
  if (groups.some((g) => g.severity === "action")) return { tone: "gold", label: `${formatCount(sum("action"))} bekliyor` };
  if (groups.some((g) => g.severity === "info")) return { tone: "info", label: `${formatCount(sum("info"))} takipte` };
  return null;
}

// Türkçede sayıdan sonra ad tekil kalır; tek şablon her sayı için doğru.
const ATTENTION_TITLES: Record<string, (n: string) => string> = {
  plan_item_overdue: (n) => `${n} ödeme planı kaleminin vadesi geçti`,
  sales_invoice_overdue: (n) => `${n} satış faturasının vadesi geçti`,
  change_order_awaiting_customer: (n) => `${n} ek iş müşteri onayında`,
  offer_expired_awaiting: (n) => `${n} teklifin süresi doldu, müşteri yanıt vermedi`,
  offer_accepted_not_converted: (n) => `${n} kabul edilen teklif projeye dönüştürülmedi`,
  purchase_request_approval: (n) => `${n} satın alma talebi onay bekliyor`,
  purchase_order_draft: (n) => `${n} sipariş taslağı onaylanmadı`,
  rfq_award: (n) => `${n} RFQ'da teklifler toplandı, karar bekliyor`,
  rfq_no_quote: (n) => `${n} RFQ'nun süresi doldu, teklif gelmedi`,
  po_late_delivery: (n) => `${n} siparişin teslimi gecikti`,
  progress_claim_certify: (n) => `${n} taşeron hakedişi onay bekliyor`,
  claim_certified_unpaid: (n) => `${n} onaylı hakedişin ödemesi yapılmadı`,
  subcontract_co_approval: (n) => `${n} taşeron değişiklik emri onay bekliyor`,
  budget_adjustment_approval: (n) => `${n} bütçe revizyonu onay bekliyor`,
  over_budget: (n) => `${n} proje bütçesini aştı`,
  active_without_budget: (n) => `${n} aktif projenin onaylı bütçesi yok`,
  contract_activation: (n) => `${n} sözleşme taslakta, aktifleştirilmedi`,
  contract_past_completion: (n) => `${n} sözleşmenin planlanan bitişi geçti`,
  active_without_contract: (n) => `${n} aktif projenin sözleşme kaydı yok`,
  project_past_end: (n) => `${n} projenin bitiş tarihi geçti`,
  my_task_overdue: (n) => `${n} görevin gecikti`,
  my_task_due_today: (n) => `${n} görevin bugün bitiyor`,
  team_task_overdue: (n) => `Ekipte ${n} görev gecikmiş`,
  team_task_unassigned: (n) => `${n} görev kimseye atanmamış`,
  milestone_overdue: (n) => `${n} iş programı kalemi gecikti`,
  attendance_not_recorded: (n) => `Bugün ${n} personelin mesaisi girilmedi`,
  users_without_project: (n) => `${n} kullanıcı hiçbir projeyi göremiyor`,
};

/** "Ulaş" / "Demir Profil" -- fiyat kaynağı kaydının adı. */
export function priceSourceName(id: string, fallback?: string): string {
  if (id === "ulas" || id === "demirprofil") return sourceLabels(id).short;
  return fallback || sourceLabels(id).short;
}

function sourceNames(g: Pick<AttentionGroup, "items">): string {
  const names = g.items.map((r) => (r.ref.kind === "price_source" ? priceSourceName(r.ref.id, r.label) : r.label));
  return names.length > 0 ? names.join(" ve ") : "Tedarikçi";
}

/** Dikkat satırı ve kart alt satırı başlığı (§3.1 şablonları). */
export function attentionTitle(g: Pick<AttentionGroup, "code" | "count" | "items">): string {
  if (g.code === "price_sync_failed") return `${sourceNames(g)} fiyat senkronu başarısız oldu`;
  if (g.code === "price_sync_never") return `${sourceNames(g)} fiyat kaynağı hiç senkronlanmadı`;
  const n = formatCount(g.count);
  const template = ATTENTION_TITLES[g.code];
  return template ? template(n) : `${n} kayıt dikkat gerektiriyor`;
}

const late = (d: number) => `${formatCount(d)} gün gecikti`;
const waiting = (d: number) => `${formatCount(d)} gündür bekliyor`;
const passed = (d: number) => `${formatCount(d)} gün geçti`;

// Kaydın gün sayısının satırdaki okunuşu (koda göre).
const DAYS_PHRASE: Record<string, (d: number) => string> = {
  plan_item_overdue: late,
  sales_invoice_overdue: late,
  po_late_delivery: late,
  my_task_overdue: late,
  team_task_overdue: late,
  milestone_overdue: late,
  change_order_awaiting_customer: waiting,
  purchase_request_approval: waiting,
  progress_claim_certify: waiting,
  budget_adjustment_approval: waiting,
  offer_expired_awaiting: (d) => `${formatCount(d)} gün önce doldu`,
  rfq_no_quote: passed,
  contract_past_completion: passed,
  project_past_end: passed,
  price_sync_failed: (d) => relativeDays(d),
};

/** 0 -> "bugün", 1 -> "dün", n -> "n gün önce". */
export function relativeDays(days: number): string {
  if (days <= 0) return "bugün";
  if (days === 1) return "dün";
  return `${formatCount(days)} gün önce`;
}

/**
 * Kaydın tek satırlık metni: kaydın kendi etiketi (sunucudan: kalem adı,
 * belge no · başlık, teklif no · müşteri ...) + proje adı (etikette zaten
 * yoksa) + koda göre gün ifadesi ya da aşım yüzdesi. Tutar ayrı gösterilir.
 */
export function attentionRecordLine(r: AttentionRecord, code: string): string {
  const parts: string[] = [];
  const label = r.ref.kind === "price_source" ? priceSourceName(r.ref.id, r.label) : r.label;
  if (label) parts.push(label);
  if (r.project_name && !label.includes(r.project_name)) parts.push(r.project_name);
  if (code === "over_budget" && r.pct !== null) {
    parts.push(`${formatPercent(r.pct)} aşım`);
  } else if (r.days !== null && DAYS_PHRASE[code]) {
    parts.push(DAYS_PHRASE[code](r.days));
  }
  return parts.join(" · ");
}

/** Grubun ikinci satırı: "en eski 21 gün" (+ birincil dışı para birimleri). */
export function attentionMeta(g: Pick<AttentionGroup, "oldest_days" | "amounts">): string {
  const parts: string[] = [];
  if (g.oldest_days !== null && g.oldest_days > 0) parts.push(`en eski ${formatCount(g.oldest_days)} gün`);
  if (g.amounts.length > 1) {
    parts.push(COPY.other(g.amounts.slice(1).map((a) => formatMoney(a.amount, a.currency)).join(" · ")));
  }
  return parts.join(" · ");
}

/** Grubun birincil tutarı (tam değer); tutarsız gruplarda null. */
export function attentionAmount(g: Pick<AttentionGroup, "amounts">): string | null {
  const a = g.amounts[0];
  return a ? formatMoney(a.amount, a.currency) : null;
}

/**
 * Grubun tek hedefi: tek kayıtlı grup doğrudan kayda, kaydı olmayan grup
 * (ör. mesai girilmedi) modül sayfasına gider; çok kayıtlı grup null
 * (açılır liste).
 */
export function attentionGroupHref(g: Pick<AttentionGroup, "count" | "items" | "module">): string | null {
  if (g.items.length === 0) return isModuleKey(g.module) ? MODULES[g.module].href : null;
  if (g.count === 1) return webHrefFor(g.items[0].ref);
  return null;
}

export function attentionAnchorId(code: string): string {
  return `dikkat-${code}`;
}

/**
 * "#dikkat-<kod>" -> kod; başka her şeyde null. Kodlar düz ASCII
 * tanımlayıcıdır (plan_item_overdue ...), bu yüzden çözümleme
 * (decodeURIComponent) YAPILMAZ: bozuk bir parça ("#dikkat-%") URIError
 * fırlatıp Dikkat panelini -- dolayısıyla sayfayı -- düşürürdü.
 */
export function attentionCodeFromHash(hash: string): string | null {
  const prefix = `#${attentionAnchorId("")}`;
  if (!hash.startsWith(prefix)) return null;
  const code = hash.slice(prefix.length);
  return /^[a-z0-9_]+$/.test(code) ? code : null;
}

const UPCOMING_LABELS: Record<string, string> = {
  plan_item_due: "Ödeme planı",
  offer_expiry: "Teklif süresi doluyor",
  po_delivery: "Sipariş teslimi",
  milestone_end: "İş programı",
  project_end: "Proje bitişi",
  my_task_due: "Görev",
};

export function upcomingLabel(kind: string): string {
  return UPCOMING_LABELS[kind] ?? "Yaklaşan";
}

/** Yaklaşan tarihinin sözcükle adı ("Bugün"/"Yarın"); diğer günlerde null (tarih bloğu çizilir). */
export function upcomingDayWord(date: ISODate, today: ISODate): "Bugün" | "Yarın" | null {
  if (date === today) return "Bugün";
  if (date === shiftDay(today, 1)) return "Yarın";
  return null;
}

// ---------------------------------------------------------------------------
// Bağlantı eşleyicileri
// ---------------------------------------------------------------------------

export type ProjectTab = "genel" | "finans" | "maliyet" | "satinalma" | "operasyon" | "dosyalar" | "aktivite";

// Proje detayının ?tab= değerleri (app/(app)/projeler/[id]/page.tsx doğrular).
export const PROJECT_TABS: readonly ProjectTab[] = ["genel", "finans", "maliyet", "satinalma", "operasyon", "dosyalar", "aktivite"];

export function parseProjectTab(raw: string | string[] | undefined): ProjectTab {
  const v = Array.isArray(raw) ? raw[0] : raw;
  return PROJECT_TABS.includes(v as ProjectTab) ? (v as ProjectTab) : "genel";
}

export function projectHref(projectId: string, tab?: ProjectTab | null): string {
  const base = `/projeler/${encodeURIComponent(projectId)}`;
  return tab && tab !== "genel" ? `${base}?tab=${tab}` : base;
}

// Proje içindeki kayıt türü -> açılacak sekme (web'de kayıt başına sayfa yok).
const PROJECT_TAB_BY_KIND: Record<string, ProjectTab> = {
  task: "operasyon",
  milestone: "operasyon",
  purchase_request: "satinalma",
  rfq: "satinalma",
  purchase_order: "satinalma",
  subcontract: "finans",
  progress_claim: "finans",
  subcontract_change_order: "finans",
  change_order: "finans",
  contract: "finans",
  payment_plan_item: "finans",
  invoice: "finans",
  budget_adjustment: "maliyet",
};

/** Nötr ref -> web yolu; eşlenemeyen (bilinmeyen tür, eksik proje) null -> satır düz metin. */
export function webHrefFor(ref: Pick<DashboardRef, "kind" | "id" | "project_id" | "action">): string | null {
  const id = encodeURIComponent(ref.id);
  switch (ref.kind) {
    case "project":
      return projectHref(ref.id);
    case "project_finance":
      return projectHref(ref.id, "finans");
    case "project_cost":
      return projectHref(ref.id, "maliyet");
    case "project_operations":
      return projectHref(ref.id, "operasyon");
    case "offer":
      return ref.action === "convert" ? `/teklifler/${id}/projeye-donustur` : `/teklifler/${id}`;
    case "customer":
      return `/musteriler/${id}`;
    case "product":
      return `/admin/urunler/${id}`;
    case "user":
      return `/admin/kullanicilar/${id}`;
    case "price_source":
      return "/admin/urunler";
  }
  const tab = PROJECT_TAB_BY_KIND[ref.kind];
  if (tab && ref.project_id) return projectHref(ref.project_id, tab);
  return null;
}

/**
 * Bildirim hedefi (backend mobil yolu yazar) -> web yolu. Web'de karşılığı
 * olmayan hedefte null (satır düz metin).
 */
export function webHrefForActionTarget(path: string | null | undefined): string | null {
  if (!path || !path.startsWith("/")) return null;
  const q = path.indexOf("?");
  const pathname = q < 0 ? path : path.slice(0, q);
  const params = new URLSearchParams(q < 0 ? "" : path.slice(q + 1));
  const seg = pathname.split("/").filter(Boolean);
  if (seg[0] === "teklifler" && seg[1] && seg[1] !== "yeni") return `/teklifler/${seg[1]}`;
  if (seg[0] === "projeler" && seg[1]) {
    const p = seg[1];
    if (seg[2] === "satin-alma") return projectHref(p, "satinalma");
    if (seg[2] === "gorevler") return projectHref(p, "operasyon");
    if (seg[2] === "taseronlar") return projectHref(p, "finans");
    if (seg.length === 2) {
      const grup = params.get("grup");
      const alt = params.get("alt");
      if (grup === "finans") return projectHref(p, alt === "maliyet" ? "maliyet" : "finans");
      if (grup === "operasyon") {
        // Mobilin operasyon grubundaki satın alma/taşeron alt görünümleri
        // web'de kendi sekmelerindedir.
        if (alt === "satin-alma") return projectHref(p, "satinalma");
        if (alt === "taseronlar") return projectHref(p, "finans");
        return projectHref(p, "operasyon");
      }
      if (grup === "dokumanlar") return projectHref(p, "dosyalar");
    }
    return projectHref(p);
  }
  if (seg[0] === "diger") {
    if (seg[1] === "musteriler" && seg[2] && seg.length === 3) return `/musteriler/${seg[2]}`;
    if (seg[1] === "mesai" && seg.length === 2) return "/mesai";
    if (seg[1] === "metraj" && seg.length === 2) return "/admin/metraj-hesaplama";
  }
  return null;
}

// ---------------------------------------------------------------------------
// Hızlı işlemler (yazma izinleriyle istemcide süzülür; sıra sabit)
// ---------------------------------------------------------------------------

export type QuickActionKey =
  | "offer"
  | "collection"
  | "expense"
  | "attendance"
  | "purchase_request"
  | "task"
  | "customer"
  | "calc"
  | "product"
  | "employee"
  | "user";

export interface QuickAction {
  key: QuickActionKey;
  label: string;
  // Doğrudan sayfa; ya da proje seçici sonrası açılacak proje sekmesi.
  href: string | null;
  pickerTab: ProjectTab | null;
}

// allOf = spec §3.5 yazma kapısı + hedef sayfanın kendi kapısı (sayfa
// yönlendiriyorsa düğme çıkmaz sokak olur). Proje seçicili işlemler
// projects.read ister: /dashboard/project-options ve /projeler/{id} bu
// izinle açılır (projects.finance.manage'in okuma kardeşi finance.read'dir,
// projects.read DEĞİL). Kullanıcı Ekle sayfası organization.roles.read de
// ister (Kullanıcılar sayfasındaki "+ Yeni Kullanıcı" ile aynı kapı).
// dashboard.test.mts hedef sayfa kapılarını ayrıca denetler.
const QUICK_ACTIONS: readonly (QuickAction & { allOf: readonly string[] })[] = [
  { key: "offer", label: "Yeni Teklif", allOf: ["offers.read", "offers.create"], href: "/teklifler/yeni", pickerTab: null },
  {
    key: "collection",
    label: "Tahsilat Gir",
    allOf: ["projects.read", "projects.finance.manage"],
    href: null,
    pickerTab: "finans",
  },
  { key: "expense", label: "Masraf Gir", allOf: ["projects.read", "projects.finance.manage"], href: null, pickerTab: "finans" },
  {
    key: "attendance",
    label: "Mesai Gir",
    allOf: ["attendance.read", "attendance.manage", "employees.read"],
    href: "/mesai",
    pickerTab: null,
  },
  {
    key: "purchase_request",
    label: "Satın Alma Talebi",
    allOf: ["projects.read", "projects.procurement.manage"],
    href: null,
    pickerTab: "satinalma",
  },
  { key: "task", label: "Görev Ekle", allOf: ["projects.read", "projects.tasks.create"], href: null, pickerTab: "operasyon" },
  {
    key: "customer",
    label: "Müşteri Ekle",
    allOf: ["customers.read", "customers.manage"],
    href: "/musteriler/yeni",
    pickerTab: null,
  },
  { key: "calc", label: "Metraj Hesapla", allOf: ["calculations.read"], href: "/admin/metraj-hesaplama", pickerTab: null },
  { key: "product", label: "Ürün Ekle", allOf: ["products.read", "products.manage"], href: "/admin/urunler/yeni", pickerTab: null },
  {
    key: "employee",
    label: "Personel Ekle",
    allOf: ["employees.read", "employees.manage"],
    href: "/admin/personel/yeni",
    pickerTab: null,
  },
  // organization.users.* / roles.read Yönetici'ye kilitli: canAccess kaba rol admin'i de ister.
  {
    key: "user",
    label: "Kullanıcı Ekle",
    allOf: ["organization.users.read", "organization.users.manage", "organization.roles.read"],
    href: "/admin/kullanicilar/yeni",
    pickerTab: null,
  },
];

/** Hızlı işlemin tam izin listesi (boş durum/kurulum CTA'ları ve testler aynı kapıyı kullanır). */
export function quickActionGate(key: QuickActionKey): readonly string[] {
  return QUICK_ACTIONS.find((a) => a.key === key)?.allOf ?? [];
}

export function quickActionsFor(user: DashboardUser): QuickAction[] {
  return QUICK_ACTIONS.filter((a) => a.allOf.every((code) => canAccess(user, code))).map(({ key, label, href, pickerTab }) => ({
    key,
    label,
    href,
    pickerTab,
  }));
}

/** Tek bir hızlı işlemin tanımı (boş durum CTA'ları aynı hedefleri kullanır); izin yoksa null. */
export function quickActionFor(user: DashboardUser, key: QuickActionKey): QuickAction | null {
  return quickActionsFor(user).find((a) => a.key === key) ?? null;
}

// ---------------------------------------------------------------------------
// Kurulum (yeni firma) adımları
// ---------------------------------------------------------------------------

export interface OnboardingStepMeta {
  title: string;
  helper: string | null;
  cta: { label: string; href: string; allOf: readonly string[] };
}

// CTA kapıları hızlı işlemlerle aynı kaynaktan (hedef sayfa aynı).
export const ONBOARDING_STEPS: Record<OnboardingStepKey, OnboardingStepMeta> = {
  customer: {
    title: "İlk müşterini ekle",
    helper: null,
    cta: { label: "Müşteri Ekle", href: "/musteriler/yeni", allOf: quickActionGate("customer") },
  },
  catalog: {
    title: "Ürün kataloğunu hazırla",
    helper: "Ulaş veya Demir Profil'den çekebilir ya da elle ekleyebilirsin.",
    cta: { label: "Ürünlere git", href: "/admin/urunler", allOf: ["products.read"] },
  },
  employee: {
    title: "Personel ekle",
    helper: null,
    cta: { label: "Personel Ekle", href: "/admin/personel/yeni", allOf: quickActionGate("employee") },
  },
  team: {
    title: "Ekibini davet et",
    helper: null,
    cta: { label: "Kullanıcı Ekle", href: "/admin/kullanicilar/yeni", allOf: quickActionGate("user") },
  },
  first_offer: {
    title: "İlk teklifini hazırla",
    helper: null,
    cta: { label: "Yeni Teklif", href: "/teklifler/yeni", allOf: quickActionGate("offer") },
  },
  convert: {
    title: "Kabul edilen teklifi projeye dönüştür",
    helper: "Müşteri teklifi kabul edince tek tıkla proje açılır.",
    cta: { label: "Tekliflere git", href: "/teklifler", allOf: ["offers.read"] },
  },
};

export const ONBOARDING_SETTINGS_LINK = { label: "Firma bilgilerini gözden geçir →", href: "/admin/firma-ayarlari" } as const;

/** Kurulum rehberini gizleme tercihinin localStorage anahtarı (firma + kullanıcı başına). */
export function onboardingHiddenKey(orgId: string, userId: string): string {
  return `arvend.home.onboarding.hidden.${orgId}.${userId}`;
}

// ---------------------------------------------------------------------------
// Nakit akışı grafiği yardımcıları
// ---------------------------------------------------------------------------

/** Eksen üst sınırı: 1, 2, 2,5, 5 × 10^k basamaklarından değeri aşmayan en küçüğü; 0 -> 0. */
export function niceCeil(value: number): number {
  if (!(value > 0)) return 0;
  const exp = Math.floor(Math.log10(value));
  const base = 10 ** exp;
  for (const step of [1, 2, 2.5, 5, 10]) {
    const candidate = step * base;
    if (candidate >= value * (1 - 1e-9)) return candidate;
  }
  return 10 * base;
}

function monthParts(ym: string): { y: number; m: number } | null {
  const match = /^(\d{4})-(\d{2})/.exec(ym);
  if (!match) return null;
  return { y: Number(match[1]), m: Number(match[2]) };
}

/** "2026-04" -> "Nis". */
export function monthShortLabel(ym: string): string {
  const p = monthParts(ym);
  return p ? MONTHS_SHORT[p.m - 1] : ym;
}

/** "2026-09" -> "Eylül 2026". */
export function monthLongLabel(ym: string): string {
  const p = monthParts(ym);
  return p ? `${MONTHS_LONG[p.m - 1]} ${p.y}` : ym;
}

/** month_start'la biten 6 ay ("YYYY-MM", eskiden yeniye) -- boş grafiğin eksenleri için. */
export function trendMonths(monthStart: ISODate): string[] {
  const p = monthParts(monthStart);
  if (!p) return [];
  const out: string[] = [];
  for (let i = 5; i >= 0; i--) {
    const t = new Date(Date.UTC(p.y, p.m - 1 - i, 1));
    out.push(`${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}`);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Metinler (§7) -- tek kaynak; mobil dashboard_registry.dart aynısını taşır
// ---------------------------------------------------------------------------

export const COPY = {
  pageTitle: "Ana Sayfa",
  greeting: (firstName: string) => (firstName ? `Merhaba, ${firstName}` : "Merhaba"),
  kpiHeading: "Temel göstergeler",
  attention: "Dikkat Gerektirenler",
  cashFlow: "Nakit Akışı",
  cashFlowPeriod: "Son 6 ay",
  myTasks: "Görevlerim",
  activity: "Son Hareketler",
  notifications: "Bildirimler",
  shortcuts: "Kısayollar",
  laneMine: "Senin sıran",
  laneWatching: "Takipte",
  laneUpcoming: "Yaklaşan · 14 gün",
  watchingTooltip: "Bu işler başka birinin onayını ya da müşteriyi bekliyor.",
  open: "Aç",
  quiet: "Bekleyen iş yok",
  refresh: "Yenile",
  updatedAt: (hm: string) => `Güncellendi ${hm}`,
  refreshFailed: (hm: string) => `Güncellenemedi · son veri ${hm}`,
  showAll: (n: number) => `Tümünü göster (${formatCount(n)})`,
  showLess: "Daha az göster",
  more: (n: number) => `+${formatCount(n)} daha`,
  records: (n: number) => `${formatCount(n)} kayıt`,
  moreActions: "Diğer işlemler",
  pickerTitle: "Proje seç",
  pickerSearch: "Proje ara…",
  pickerEmpty: "Açık proje bulunamadı.",
  pickerError: "Projeler yüklenemedi.",
  pickerLoading: "Yükleniyor…",
  pickerCount: (n: number) => `${formatCount(n)} proje`,
  other: (values: string) => `Diğer: ${values}`,
  chartIn: "Tahsilat",
  chartOut: "Çıkış",
  thisMonth: "Bu ay",
  expenses: "Masraf",
  subcontractPayments: "Taşeron ödemesi",
  net: "Net",
  unread: (n: number) => `${formatCount(n)} okunmamış`,
  markAllRead: "Tümünü okundu say",
  markAllReadFailed: "Bildirimler okundu olarak işaretlenemedi.",
  notificationsEmpty: "Yeni bildirim yok.",
  activityEmpty: "Henüz hareket yok.",
  attentionEmpty: "Her şey yolunda — seni bekleyen onay ya da gecikme yok.",
  cashEmpty: "Son 6 ayda tahsilat ya da ödeme kaydı yok.",
  myTasksEmpty: "Sana atanmış açık görev yok.",
  sectionError: "Bu özet şu an yüklenemedi.",
  retry: "Tekrar dene",
  partial: "Bazı bölümler yüklenemedi; liste eksik olabilir.",
  unavailableTitle: "Özet yüklenemedi",
  unavailableBody: "Bağlantını kontrol edip tekrar dene. Modüllere aşağıdaki kısayollardan ulaşabilirsin.",
  onboardingTitle: "Kurulum — ilk adımlar",
  onboardingProgress: (done: number, total: number) => `${done} / ${total} tamamlandı`,
  onboardingHide: "Gizle",
  onboardingHidden: "Kurulum rehberi gizlendi",
  onboardingShow: "Göster",
  projectModules: "Proje modülleri",
  projectModulesBody:
    "Proje başladığında finans, ek iş, sözleşme, görev, şantiye, satın alma, taşeron ve bütçe özetleri burada görünecek.",
  firmWide: "Firma geneli",
  subcontractPaidInfo: "Hakedişe bağlanmamış avans ödemeleri 'ödenmemiş' tutarını azaltmaz.",
  subcontractWebNote: "Taşeron hakediş ve değişiklik emirleri şimdilik mobil uygulamada yönetilir.",
} as const;

// Boş durum metinleri (§7.4). CTA'lar kartta ilgili yazma izniyle gösterilir.
export const EMPTY = {
  finance: "Henüz tahsilat ya da masraf kaydı yok. Kayıtlar proje sayfasındaki Finans sekmesinden girilir.",
  offers: "Henüz teklif yok. İlk teklifini hazırlayıp müşterine bağlantıyla gönderebilirsin.",
  changeOrders:
    "Bekleyen ek iş yok. Sözleşme dışı işler için proje sayfasından ek iş oluşturup müşteriye onaya gönderebilirsin.",
  projectsAll: "Henüz proje yok. Projeler, kabul edilen tekliflerden oluşturulur.",
  projectsRestricted: "Henüz bir projeye eklenmedin. Yöneticin seni bir projeye eklediğinde projelerin burada görünür.",
  projectsNoOpen: (completed: number) => `Açık proje yok · ${formatCount(completed)} tamamlanan proje`,
  tasksNotLinked:
    "Hesabın bir personel kaydına bağlı değil; sana atanan görevler burada görünmez. Yöneticinden bağlamasını iste.",
  operations: "Son 7 günde şantiye kaydı yok.",
  contracts: "Henüz sözleşme kaydı yok. Sözleşmeler proje sayfasındaki Finans sekmesinden açılır.",
  attendanceNoEmployees: "Mesai takibi için önce personel ekle.",
  attendanceSunday: "Bugün Pazar — mesai beklenmiyor.",
  attendanceNothing: "Bugün için mesai kaydı girilmedi.",
  procurement: "Açık satın alma kaydı yok. Malzeme ihtiyacı proje sayfasındaki Satın Alma sekmesinden talep edilir.",
  subcontracts: "Henüz taşeron sözleşmesi yok.",
  costControl: "Henüz bütçe oluşturulmadı. Bütçe, maliyet kontrolünün temelidir.",
  customers: "Henüz müşteri yok.",
  employees: "Henüz personel eklenmedi.",
  products: "Katalog boş. Ulaş veya Demir Profil fiyat kaynağını bağlayarak ürünleri içe aktarabilirsin.",
  productsNoSource: "Fiyat kaynağı bağlı değil.",
  users: "Ekipte yalnızca sen varsın. Ekip arkadaşlarını davet et.",
  calculations: "Henüz metraj grubu yok.",
  suppliers: "Henüz tedarikçi yok.",
  costCodes: "Henüz maliyet kodu yok.",
} as const;

/** Karşılamadaki ad: tam adın ilk sözcüğü. */
export function firstName(fullName: string | null | undefined): string {
  return (fullName ?? "").trim().split(/\s+/)[0] ?? "";
}

/** Fiyat kaynağı rozeti durumu. */
export function syncStatusLabel(status: string): string {
  if (status === "success") return "Başarılı";
  if (status === "failed") return "Hata";
  return "Hiç senkronlanmadı";
}


// Masraf onayının (backend migration 0060) saf yardımcıları -- Finans
// sekmesi ve Maliyet > Gerçekleşen kullanır, node testleri (expenses.test.mts)
// içe aktarır. Kural backend toplamlarıyla aynı: yalnızca ONAYLI ve iptal
// edilmemiş masraf sayılır; bekleyen/reddedilen listede durumuyla görünür.
// Ayrıca KDV (0065), form gövdesi ve "masrafı herkes girer" (0066) kuralları
// -- Finans tablosu, proje sayfasındaki ayrı giriş ve Masraflarım AYNI
// kararları kullanır (mobil expense_actions.dart ile aynı).
import { parseAmountTR } from "./format.ts";
import type { Expense } from "./types";

type ExpenseLike = Pick<Expense, "amount" | "voided_at" | "approval_status">;
type ExpenseState = Pick<Expense, "voided_at" | "approval_status">;

/** Masraf para toplamlarına girer mi (onaylı ve iptal edilmemiş). */
export function expenseCounts(e: ExpenseState): boolean {
  return !e.voided_at && e.approval_status === "approved";
}

/** Onay bekleyen (iptal edilmemiş) masraf. */
export function expenseIsPending(e: ExpenseState): boolean {
  return !e.voided_at && e.approval_status === "pending";
}

export interface ExpenseApprovalSummary {
  /** Onaylı masrafların toplamı -- finans özetindeki "masraf toplamı". */
  approvedTotal: number;
  pendingCount: number;
  pendingTotal: number;
}

export function summarizeExpenses(expenses: ExpenseLike[]): ExpenseApprovalSummary {
  const out: ExpenseApprovalSummary = { approvedTotal: 0, pendingCount: 0, pendingTotal: 0 };
  for (const e of expenses) {
    if (expenseCounts(e)) out.approvedTotal += e.amount;
    else if (expenseIsPending(e)) {
      out.pendingCount += 1;
      out.pendingTotal += e.amount;
    }
  }
  // Kuruş toplamları ikili kayan noktada sürüklenmesin (0.1 + 0.2).
  out.approvedTotal = Math.round(out.approvedTotal * 100) / 100;
  out.pendingTotal = Math.round(out.pendingTotal * 100) / 100;
  return out;
}

// ---------------------------------------------------------------------------
// KDV (backend migration 0065)
// ---------------------------------------------------------------------------

/** Formdaki KDV seçenekleri (mobil kExpenseVatRates ile aynı); null = Belirtilmedi. */
export const EXPENSE_VAT_RATES: readonly number[] = [0, 1, 10, 20];

/** Oranın kendisi: 0 -> "%0", 20 -> "%20", 18.5 -> "%18,5" (ayrıntıdaki "KDV (%20)" satırı). */
export function expenseVatPercent(rate: number): string {
  return `%${rate.toLocaleString("tr-TR", { useGrouping: false, maximumFractionDigits: 2 })}`;
}

/** Seçenek etiketi: 0 -> "KDV yok (%0)", 20 -> "%20", 18.5 -> "%18,5". */
export function expenseVatRateLabel(rate: number): string {
  const pct = expenseVatPercent(rate);
  return rate === 0 ? `KDV yok (${pct})` : pct;
}

/**
 * Gösterilecek oranlar: standart dört oran + düzenlenen masrafın standart
 * dışı oranı (API'den girilmiş ör. %18) -- o oran seçili görünür ve aynen
 * geri gider.
 */
export function expenseVatRateOptions(current: number | null | undefined): number[] {
  const rates = [...EXPENSE_VAT_RATES];
  if (current != null && !rates.includes(current)) rates.push(current);
  return rates;
}

/**
 * Canlı "KDV hariç · KDV" önizlemesi. Asıl tutarları sunucu AYNI formülle
 * hesaplar: KDV = round(tutar × oran / (100 + oran), 2), hariç = tutar − KDV.
 * Tutar geçersiz/sıfırsa null.
 */
export function expenseVatSplit(amount: number, rate: number): { vat: number; net: number } | null {
  if (!Number.isFinite(amount) || amount <= 0 || !Number.isFinite(rate) || rate < 0) return null;
  const vat = Math.round(((amount * rate) / (100 + rate)) * 100) / 100;
  const net = Math.round((amount - vat) * 100) / 100;
  return { vat, net };
}

/**
 * Finans özetindeki "Maliyet (KDV hariç)" satırı yalnızca brütten farklıysa
 * gösterilir (masraflara KDV girilmemişse aynı rakamı iki kez yazmanın anlamı
 * yok; mobil realizedCostNetDiffers ile aynı). Alanı döndürmeyen eski
 * sunucuda (undefined) gösterilmez.
 */
export function costNetDiffers(gross: number, net: number | null | undefined): boolean {
  return typeof net === "number" && Number.isFinite(net) && Math.abs(gross - net) >= 0.005;
}

// ---------------------------------------------------------------------------
// Form ve istek gövdesi
// ---------------------------------------------------------------------------

export interface ExpenseFormValues {
  // Bilinmeyen (yeni sunucu) kategori düzenlemede aynen kalır.
  category: string;
  description: string;
  // Kullanıcının yazdığı tutar: Türkçe yazım ("64.000" = 64 000,
  // "1.250,50") parseAmountTR ile okunur (mobil parseAmountInput ile aynı).
  amount: string;
  expense_date: string;
  supplier_name: string;
  invoice_no: string;
  notes: string;
  change_order_id: string;
  // Maliyet Kontrolü (Sprint 2) eşlemesi -- ikisi de opsiyonel.
  cost_code_id: string;
  budget_line_id: string;
  // null = Belirtilmedi (gövdeye HİÇ konmaz).
  vat_rate: number | null;
}

export function emptyExpenseForm(today: string): ExpenseFormValues {
  return {
    category: "material",
    description: "",
    amount: "",
    expense_date: today,
    supplier_name: "",
    invoice_no: "",
    notes: "",
    change_order_id: "",
    cost_code_id: "",
    budget_line_id: "",
    vat_rate: null,
  };
}

/** Ön doldurulan tutar parseAmountTR'nin okuduğu Türkçe yazımla: 1250.5 -> "1.250,5". */
export function expenseAmountInput(amount: number): string {
  return amount.toLocaleString("tr-TR", { maximumFractionDigits: 2 });
}

/** Formdaki tutar; geçersiz ya da sıfır/eksiyse null ("Geçerli bir tutar girin"). */
export function parseExpenseAmount(raw: string): number | null {
  const amount = parseAmountTR(raw);
  return Number.isFinite(amount) && amount > 0 ? amount : null;
}

/** Düzenleme: form okunan masrafın TÜM alanlarıyla dolar (bağlar ve KDV dahil). */
export function expenseFormFrom(e: Expense): ExpenseFormValues {
  return {
    category: e.category,
    description: e.description,
    amount: expenseAmountInput(e.amount),
    expense_date: e.expense_date.slice(0, 10),
    supplier_name: e.supplier_name,
    invoice_no: e.invoice_no,
    notes: e.notes,
    change_order_id: e.change_order_id ?? "",
    cost_code_id: e.cost_code_id ?? "",
    budget_line_id: e.budget_line_id ?? "",
    vat_rate: e.vat_rate ?? null,
  };
}

/**
 * POST/PUT gövdesi. PUT satırı BÜTÜNÜYLE yeniden yazar: formun her alanı
 * (kullanıcının değiştirmediği bağlar, not, tarih dahil) geri gider;
 * vat_rate yalnızca oran seçiliyse konur (yoksa sunucu "Belirtilmedi"
 * yazar -- alanı tanımayan eski sunucuda da masraf girişi bozulmaz).
 *
 * canLink (projects.finance.manage) yoksa üç bağ BOŞ gider: sunucu dolu
 * bağı 403 ile reddeder, düzenlemede boş bağ "kayıttakini koru" demektir
 * (backend 0066; mobil ile aynı).
 */
export function expenseRequestBody(
  v: ExpenseFormValues,
  opts: { currency: string; canLink: boolean; idempotencyKey?: string }
): Record<string, unknown> {
  const link = (id: string) => (opts.canLink ? id : "");
  return {
    category: v.category,
    description: v.description.trim(),
    amount: parseAmountTR(v.amount),
    currency: opts.currency,
    expense_date: v.expense_date,
    supplier_name: v.supplier_name.trim(),
    invoice_no: v.invoice_no.trim(),
    notes: v.notes.trim(),
    change_order_id: link(v.change_order_id),
    cost_code_id: link(v.cost_code_id),
    budget_line_id: link(v.budget_line_id),
    ...(v.vat_rate == null ? {} : { vat_rate: v.vat_rate }),
    ...(opts.idempotencyKey ? { idempotency_key: opts.idempotencyKey } : {}),
  };
}

// ---------------------------------------------------------------------------
// Kim ne yapabilir (backend migration 0066; mobil expenseActionsFor ile aynı)
// ---------------------------------------------------------------------------

type OwnedExpense = Pick<Expense, "voided_at" | "approval_status" | "created_by" | "voided_by">;

/** Giren kişi kendisi geri çekti (iptal eden = giren): "Geri çekildi". */
export function expenseIsWithdrawn(e: Pick<Expense, "voided_at" | "created_by" | "voided_by">): boolean {
  return !!e.voided_at && !!e.created_by && e.voided_by === e.created_by;
}

/** Oturumdaki kişinin masraf yetkileri (sayfa sunucuda bir kez hesaplar). */
export interface ExpenseActor {
  userId: string | null;
  // Firma Sahibi: üstünde onaylayacak kimse olmadığından kendi masrafına karar verebilir.
  isOwner: boolean;
  // projects.finance.manage: her masrafı düzenler/iptal eder, bağları yazar.
  canManageFinance: boolean;
  // projects.expenses.create: masraf girer; kendi bekleyen/reddedilen masrafını düzenler/geri çeker.
  canCreate: boolean;
  // projects.expenses.approve: Onayla/Reddet.
  canApprove: boolean;
}

export const EXPENSE_CREATE_PERMISSION = "projects.expenses.create";
export const EXPENSE_APPROVE_PERMISSION = "projects.expenses.approve";
export const EXPENSE_FINANCE_MANAGE_PERMISSION = "projects.finance.manage";

/** Fail-closed (web'in hasPermission kuralı): izin kümesi yoksa hiçbir yetki yok. */
export function expenseActorFor(
  user: { id: string; organization_role_code?: string; permissions?: readonly string[] } | null | undefined
): ExpenseActor {
  const has = (code: string) => user?.permissions?.includes(code) ?? false;
  return {
    userId: user?.id ?? null,
    isOwner: user?.organization_role_code === "owner",
    canManageFinance: has(EXPENSE_FINANCE_MANAGE_PERMISSION),
    canCreate: has(EXPENSE_CREATE_PERMISSION),
    canApprove: has(EXPENSE_APPROVE_PERMISSION),
  };
}

export interface ExpenseActions {
  // "Düzenle": finans yöneticisi her masrafta; diğerleri yalnızca kendi
  // girdiği, onay bekleyen ya da reddedilen masrafta.
  canEdit: boolean;
  // "İptal Et" (gerekçeli): yalnızca finans yöneticisi.
  canVoid: boolean;
  // "Geri Çek" (gerekçesiz): finans yöneticisi olmayan kişi, kendi bekleyen/reddedilen masrafında.
  canWithdraw: boolean;
  // "Onayla" / "Reddet": onay izni + bekleyen masraf + kendi masrafı değil (Sahip hariç).
  canDecide: boolean;
  // Onaylayıcı ama masrafı kendisi girdi (Sahip değil): düğmeler yerine kısa not.
  ownDecisionBlocked: boolean;
}

/**
 * Bir masrafta kişinin yapabilecekleri. open: proje açık mı (tamamlanmış/
 * iptal projede finans hareketi yok). Yalnızca görünürlüktür; sunucu her
 * işlemi yeniden denetler (403/409 mesajı olduğu gibi gösterilir).
 */
export function expenseActionsFor(actor: ExpenseActor, e: OwnedExpense, open: boolean): ExpenseActions {
  const live = open && !e.voided_at;
  const own = !!actor.userId && e.created_by === actor.userId;
  const ownEditable = own && e.approval_status !== "approved" && actor.canCreate;
  const decidable = live && e.approval_status === "pending" && actor.canApprove;
  return {
    canEdit: live && (actor.canManageFinance || ownEditable),
    canVoid: live && actor.canManageFinance,
    canWithdraw: live && !actor.canManageFinance && ownEditable,
    canDecide: decidable && (!own || actor.isOwner),
    ownDecisionBlocked: decidable && own && !actor.isOwner,
  };
}

/** Onaylayıcının kendi masrafındaki not (mobil kExpenseOwnDecisionText). */
export const EXPENSE_OWN_DECISION_TEXT = "Bu masrafı sen girdin; başka bir yöneticinin onaylaması gerekir.";

/** Tamamlanmış/iptal edilmiş projede masraf hareketi yok (backend 409). */
export function projectLedgerOpen(status: string): boolean {
  return status !== "completed" && status !== "cancelled";
}

// ---------------------------------------------------------------------------
// Masraflarım (GET /expenses/mine)
// ---------------------------------------------------------------------------

/** Web rotası (mobil /diger/masraflarim). */
export const MY_EXPENSES_PATH = "/masraflarim";

/** ?proje= proje süzgeci, ?masraf= o masrafın ayrıntısını bir kez açar (mobil ile aynı parametreler). */
export function myExpensesHref(opts: { projectId?: string | null; expenseId?: string | null } = {}): string {
  const params = new URLSearchParams();
  if (opts.projectId) params.set("proje", opts.projectId);
  if (opts.expenseId) params.set("masraf", opts.expenseId);
  const qs = params.toString();
  return qs ? `${MY_EXPENSES_PATH}?${qs}` : MY_EXPENSES_PATH;
}

export type MyExpenseFilter = "all" | "pending" | "rejected" | "approved";

/** "Tümü" geri çekilen/iptal edilenleri de gösterir; durum süzgeçleri yalnızca iptal edilmemişleri. */
export const MY_EXPENSE_FILTERS: readonly { key: MyExpenseFilter; label: string }[] = [
  { key: "all", label: "Tümü" },
  { key: "pending", label: "Onay bekliyor" },
  { key: "rejected", label: "Reddedildi" },
  { key: "approved", label: "Onaylandı" },
];

export function myExpenseMatches(filter: MyExpenseFilter, e: ExpenseState): boolean {
  switch (filter) {
    case "all":
      return true;
    case "pending":
      return expenseIsPending(e);
    case "rejected":
      return !e.voided_at && e.approval_status === "rejected";
    case "approved":
      return !e.voided_at && e.approval_status === "approved";
  }
}

/** "PRJ-2026-001 · Ataşehir Konut" -- numara yoksa yalnızca ad. */
export function expenseProjectLabel(projectNo: string, projectName: string): string {
  return projectNo ? `${projectNo} · ${projectName}` : projectName;
}

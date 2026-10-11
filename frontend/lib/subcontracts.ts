// Sprint 5 — Taşeron sözleşme modülü (`/projects/{id}/subcontracts`, yeni
// sistem) için web'in SAF yardımcıları: yanıt tipleri, durum etiketleri,
// durum+izin -> görünür eylem eşlemesi, form taslaklarından istek gövdesi,
// hakediş önizlemesi ve hakediş sınırı (claim cap) kontrolleri, bağlantılar.
// next/* ya da React içermez; sayfalar ve node testleri
// (subcontracts.test.mts) içe aktarır.
//
// Legacy `/subcontractors` (Finans > Taşeron Ödemeleri, FinanceSections.tsx)
// İLE KARIŞTIRILMAMALI -- o basit taşeron+ödeme defteri bu modülden tamamen
// ayrıdır (bkz. docs/subcontracts.md §0).
//
// Davranışın kaynağı mobil ekranlardır (mobile/lib/features/projects/
// presentation/subcontract_*.dart, progress_claim_*.dart) ve backend
// router.go "Sprint 5: Taşeron Yönetimi" / "Taşeron Ödemeleri". Buradaki
// görünürlük kuralları yalnızca UX'tir; backend her geçişi kendi durum
// korumalı SQL'iyle bağımsız olarak reddeder ve 403/409 mesajı olduğu gibi
// gösterilir.
import { parseAmountTR } from "./format.ts";
import { hasPermission } from "./permissions.ts";
import type { StatusMeta } from "./status";
import type { Commitment } from "./types";

// ---------------------------------------------------------------------------
// Tipler (backend handler/subcontract_*.go yanıtlarının birebir karşılığı)
// ---------------------------------------------------------------------------

export type SubcontractStatus = "draft" | "active" | "completed" | "cancelled" | "terminated";

export interface Subcontract {
  id: string;
  subcontract_no: string;
  supplier_id: string;
  supplier_code?: string;
  supplier_name?: string;
  title: string;
  scope_summary: string;
  // SOV kalemlerinden TÜRETİLİR (bkz. docs/subcontracts.md §4) -- doğrudan
  // yazılamaz.
  original_amount: number;
  currency: string;
  status: SubcontractStatus;
  effective_date?: string | null;
  start_date?: string | null;
  planned_completion_date?: string | null;
  retention_percent?: number | null;
  advance_amount?: number | null;
  payment_terms: string;
  notes: string;
  activated_at?: string | null;
  completed_at?: string | null;
  cancelled_at?: string | null;
  cancel_reason?: string;
  terminated_at?: string | null;
  termination_reason?: string;
  created_at: string;
  updated_at: string;
}

/** SOV (Schedule of Values) kalemi. quantity/unit/unit_price üçü de opsiyoneldir. */
export interface SubcontractItem {
  id: string;
  wbs_node_id?: string | null;
  cost_code_id: string;
  budget_line_id?: string | null;
  description: string;
  quantity?: number | null;
  unit: string;
  unit_price?: number | null;
  original_amount: number;
  sort_order: number;
}

/**
 * `GET /subcontracts/{id}` yanıtının `current_value` alt nesnesi -- backend
 * HER ZAMAN otoriterdir. Taahhüt ekseni (certified_to_date /
 * remaining_commitment) ile nakit ekseni (paid_to_date / remaining_payable)
 * BİLİNÇLİ OLARAK ayrıdır: sertifikasyon ödeme değildir.
 */
export interface SubcontractValue {
  original_amount: number;
  approved_additions: number;
  approved_deductions: number;
  pending_additions: number;
  pending_deductions: number;
  current_value: number;
  certified_to_date: number;
  remaining_commitment: number;
  paid_to_date: number;
  remaining_payable: number;
}

export interface SubcontractDetail {
  subcontract: Subcontract;
  items: SubcontractItem[];
  current_value: SubcontractValue;
  commitments: Commitment[];
}

export type ProgressClaimStatus = "draft" | "submitted" | "certified" | "rejected" | "cancelled";

/** Taşeron hakedişi. `net_payable` bir YÜKÜMLÜLÜKTÜR, ödendiği anlamına gelmez. */
export interface ProgressClaim {
  id: string;
  subcontract_id: string;
  claim_number: string;
  period_start?: string | null;
  period_end: string;
  status: ProgressClaimStatus;
  gross_work_amount: number;
  retention_percent_snapshot: number;
  retention_amount: number;
  advance_recovery_amount: number;
  other_deductions: number;
  previous_certified_amount: number;
  current_certified_amount: number;
  net_payable: number;
  submitted_at?: string | null;
  certified_at?: string | null;
  rejected_at?: string | null;
  rejection_reason?: string;
  cancelled_at?: string | null;
  notes: string;
  created_at: string;
  updated_at: string;
}

export interface ProgressClaimItem {
  id: string;
  subcontract_item_id: string;
  item_description: string;
  item_unit: string;
  // SNAPSHOT: hakediş oluşturulduğu andaki kalem sınırı.
  scheduled_value: number;
  previous_progress_amount: number;
  current_progress_amount: number;
  cumulative_progress_amount: number;
  progress_percent: number;
  remaining_amount: number;
  sort_order: number;
}

export type SubcontractChangeOrderStatus = "draft" | "submitted" | "approved" | "rejected" | "cancelled";
export type SubcontractChangeType = "addition" | "deduction";

/**
 * Taşeron değişiklik emri (ek iş / kesinti, MALİYET tarafı). Proje
 * düzeyindeki müşteri "Ek İşler"i (`/change-orders`, gelir tarafı) İLE
 * KARIŞTIRILMAMALI. `amount` her zaman pozitiftir; işaret `change_type`'tan.
 */
export interface SubcontractChangeOrder {
  id: string;
  subcontract_id: string;
  number: string;
  title: string;
  description: string;
  change_type: SubcontractChangeType;
  amount: number;
  status: SubcontractChangeOrderStatus;
  reason: string;
  requested_at?: string | null;
  approved_at?: string | null;
  rejected_at?: string | null;
  rejection_reason?: string;
  cancelled_at?: string | null;
  created_at: string;
  updated_at: string;
}

export interface SubcontractChangeOrderItem {
  id: string;
  wbs_node_id?: string | null;
  cost_code_id: string;
  budget_line_id?: string | null;
  description: string;
  amount: number;
  sort_order: number;
}

/** GERÇEK nakit çıkışı (migration 0039) -- hakediş sertifikasyonu DEĞİLDİR. */
export interface SubcontractPayment {
  id: string;
  subcontract_id: string;
  progress_claim_id: string | null;
  amount: number;
  currency: string;
  paid_date: string;
  payment_method: string;
  reference_no: string;
  description: string;
  voided_at: string | null;
  void_reason: string;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Durum etiketleri (mobil core/widgets/status_badge.dart ile aynı metinler)
// ---------------------------------------------------------------------------

export const SUBCONTRACT_STATUS: Record<SubcontractStatus, StatusMeta> = {
  draft: { label: "Taslak", tone: "muted" },
  active: { label: "Aktif", tone: "gold" },
  completed: { label: "Tamamlandı", tone: "success" },
  cancelled: { label: "İptal Edildi", tone: "danger" },
  terminated: { label: "Feshedildi", tone: "danger" },
};

export const PROGRESS_CLAIM_STATUS: Record<ProgressClaimStatus, StatusMeta> = {
  draft: { label: "Taslak", tone: "muted" },
  submitted: { label: "Gönderildi", tone: "info" },
  certified: { label: "Sertifika Edildi", tone: "success" },
  rejected: { label: "Reddedildi", tone: "danger" },
  cancelled: { label: "İptal Edildi", tone: "danger" },
};

export const SUBCONTRACT_CHANGE_ORDER_STATUS: Record<SubcontractChangeOrderStatus, StatusMeta> = {
  draft: { label: "Taslak", tone: "muted" },
  submitted: { label: "Gönderildi", tone: "info" },
  approved: { label: "Onaylandı", tone: "success" },
  rejected: { label: "Reddedildi", tone: "danger" },
  cancelled: { label: "İptal Edildi", tone: "danger" },
};

export const CHANGE_TYPE_LABELS: Record<SubcontractChangeType, string> = {
  addition: "Ek İş (+)",
  deduction: "Kesinti (−)",
};

/**
 * Durum -> rozet bilgisi; sözlükte olmayan (sonradan eklenmiş) bir durum
 * sayfayı çökertmez, ham değeriyle gri rozet olarak görünür.
 */
export function statusMetaFor(registry: Record<string, StatusMeta>, status: string): StatusMeta {
  return registry[status] ?? { label: status, tone: "muted" };
}

// ---------------------------------------------------------------------------
// İzinler ve durum -> eylem eşlemesi
// ---------------------------------------------------------------------------

/**
 * Her adımın ayrı izni vardır (router.go): sözleşme/değişiklik emri
 * oluşturma-düzenleme-gönderme-iptal = subcontracts.manage; aktifleştir/
 * tamamla/iptal/feshet ve değişiklik onay/red = subcontracts.approve;
 * hakediş oluşturma-düzenleme-gönderme-iptal = subcontract_claims.manage;
 * hakediş sertifika/red = subcontract_claims.certify (red bile certify
 * ister); ödeme = subcontract_payments.read/.manage (sözleşme izinlerinden
 * AYRI).
 */
export interface SubcontractPerms {
  canRead: boolean;
  canManage: boolean;
  canApprove: boolean;
  canReadClaims: boolean;
  canManageClaims: boolean;
  canCertifyClaims: boolean;
  canReadPayments: boolean;
  canManagePayments: boolean;
}

export function subcontractPermsFrom(permissions: readonly string[] | undefined): SubcontractPerms {
  const has = (code: string) => hasPermission(permissions, code);
  return {
    canRead: has("projects.subcontracts.read"),
    canManage: has("projects.subcontracts.manage"),
    canApprove: has("projects.subcontracts.approve"),
    canReadClaims: has("projects.subcontract_claims.read"),
    canManageClaims: has("projects.subcontract_claims.manage"),
    canCertifyClaims: has("projects.subcontract_claims.certify"),
    canReadPayments: has("projects.subcontract_payments.read"),
    canManagePayments: has("projects.subcontract_payments.manage"),
  };
}

/** Tamamlanmış/iptal edilmiş projede finans hareketleri kilitlidir (diğer sekmelerle aynı). */
export function projectIsLocked(projectStatus: string): boolean {
  return projectStatus === "completed" || projectStatus === "cancelled";
}

export interface SubcontractActionSet {
  edit: boolean;
  activate: boolean;
  cancel: boolean;
  complete: boolean;
  terminate: boolean;
  addChangeOrder: boolean;
  addClaim: boolean;
  addPayment: boolean;
}

const NO_SUBCONTRACT_ACTIONS: SubcontractActionSet = {
  edit: false,
  activate: false,
  cancel: false,
  complete: false,
  terminate: false,
  addChangeOrder: false,
  addClaim: false,
  addPayment: false,
};

/**
 * Sözleşme durumu + izin -> görünür eylemler. Kapalı projede hiçbir yazma
 * eylemi görünmez (diğer proje sekmeleriyle aynı desen).
 *   draft  -> Düzenle (manage), Aktifleştir / İptal Et (approve)
 *   active -> Tamamla / Feshet (approve), Değişiklik Emri (manage),
 *             Hakediş (claims.manage)
 * Ödeme yalnızca aktif, tamamlanmış ya da feshedilmiş sözleşmeye kaydedilir
 * (backend ErrSubcontractNotPayable).
 */
export function subcontractActions(status: string, perms: SubcontractPerms, locked: boolean): SubcontractActionSet {
  if (locked) return NO_SUBCONTRACT_ACTIONS;
  const draft = status === "draft";
  const active = status === "active";
  return {
    edit: draft && perms.canManage,
    activate: draft && perms.canApprove,
    cancel: draft && perms.canApprove,
    complete: active && perms.canApprove,
    terminate: active && perms.canApprove,
    addChangeOrder: active && perms.canManage,
    addClaim: active && perms.canManageClaims,
    addPayment: (active || status === "completed" || status === "terminated") && perms.canManagePayments,
  };
}

export interface ReviewActionSet {
  edit: boolean;
  submit: boolean;
  cancel: boolean;
  approve: boolean;
  reject: boolean;
}

const NO_REVIEW_ACTIONS: ReviewActionSet = { edit: false, submit: false, cancel: false, approve: false, reject: false };

/**
 * Değişiklik emri: draft -> submitted -> {approved, rejected};
 * {draft, submitted} -> cancelled. Onay yalnızca sözleşme AKTİFKEN mümkün
 * (backend ErrSubcontractNotActiveForChange) -- aktif olmayan sözleşmede
 * Onayla gösterilmez, Reddet gösterilir.
 */
export function changeOrderActions(
  status: string,
  subcontractStatus: string,
  perms: SubcontractPerms,
  locked: boolean
): ReviewActionSet {
  if (locked) return NO_REVIEW_ACTIONS;
  const draft = status === "draft";
  const submitted = status === "submitted";
  return {
    edit: draft && perms.canManage,
    submit: draft && perms.canManage,
    cancel: (draft || submitted) && perms.canManage,
    approve: submitted && perms.canApprove && subcontractStatus === "active",
    reject: submitted && perms.canApprove,
  };
}

/**
 * Hakediş: draft -> submitted -> {certified, rejected}; {draft, submitted}
 * -> cancelled. Sertifika yalnızca aktif ya da tamamlanmış sözleşmede
 * (feshedilmişte backend ErrSubcontractNotCertifiable döner); `approve`
 * burada "Sertifikala"dır.
 */
export function claimActions(
  status: string,
  subcontractStatus: string,
  perms: SubcontractPerms,
  locked: boolean
): ReviewActionSet {
  if (locked) return NO_REVIEW_ACTIONS;
  const draft = status === "draft";
  const submitted = status === "submitted";
  return {
    edit: draft && perms.canManageClaims,
    submit: draft && perms.canManageClaims,
    cancel: (draft || submitted) && perms.canManageClaims,
    approve:
      submitted && perms.canCertifyClaims && (subcontractStatus === "active" || subcontractStatus === "completed"),
    reject: submitted && perms.canCertifyClaims,
  };
}

/** Ödeme iptali: iptal edilmemiş ödeme + payments.manage + açık proje. */
export function canVoidPayment(payment: Pick<SubcontractPayment, "voided_at">, perms: SubcontractPerms, locked: boolean): boolean {
  return !locked && perms.canManagePayments && !payment.voided_at;
}

// ---------------------------------------------------------------------------
// Bağlantılar
// ---------------------------------------------------------------------------

/** Proje detayındaki taşeron sekmesinin ?tab= değeri (lib/dashboard.ts ProjectTab). */
export const SUBCONTRACT_PROJECT_TAB = "taseron";

export function subcontractsTabHref(projectId: string): string {
  return `/projeler/${encodeURIComponent(projectId)}?tab=${SUBCONTRACT_PROJECT_TAB}`;
}

/**
 * Sözleşme detay sayfası (mobil yolun aynısı: /projeler/{id}/taseronlar/
 * {sözleşme}); hakediş/değişiklik emri bağlantıları o kaydı açık getirir.
 */
export function subcontractHref(
  projectId: string,
  subcontractId: string,
  focus?: { claimId?: string | null; changeOrderId?: string | null }
): string {
  const base = `/projeler/${encodeURIComponent(projectId)}/taseronlar/${encodeURIComponent(subcontractId)}`;
  if (focus?.claimId) return `${base}?hakedis=${encodeURIComponent(focus.claimId)}`;
  if (focus?.changeOrderId) return `${base}?degisiklik=${encodeURIComponent(focus.changeOrderId)}`;
  return base;
}

// ---------------------------------------------------------------------------
// Para yardımcıları
// ---------------------------------------------------------------------------

/** 2 haneye yuvarlar (kuruş); 1.005 -> 1.01 (ikili kayan nokta kayması düzeltilir). */
export function round2(n: number): number {
  const r = Math.round(Math.abs(n) * 100 + 1e-7) / 100;
  return n < 0 ? -r : r;
}

function cents(n: number): number {
  return Math.round(n * 100);
}

/** Değişiklik emrinin görüntüleme işareti: ek iş +, kesinti −. */
export function signedChangeOrderAmount(co: Pick<SubcontractChangeOrder, "amount" | "change_type">): number {
  return co.change_type === "deduction" ? -co.amount : co.amount;
}

/**
 * Ödemenin bağlanabileceği hakedişler: yalnızca SERTİFİKALI olanlar (backend
 * ErrSubcontractPaymentClaimInvalid; mobil ProgressClaim.isPayable).
 */
export function payableClaims<T extends { status: string }>(claims: readonly T[]): T[] {
  return claims.filter((c) => c.status === "certified");
}

/** Bu hakedişe bağlı, iptal edilmemiş ödemelerin toplamı. */
export function paidAgainstClaim(payments: readonly SubcontractPayment[], claimId: string): number {
  return round2(
    payments.filter((p) => p.progress_claim_id === claimId && !p.voided_at).reduce((sum, p) => sum + p.amount, 0)
  );
}

/**
 * Hakedişin ödenmemiş kalanı = NET hakediş − ona bağlı ödenen (mobil
 * claimUnpaidRemainder ile aynı). Kümülatif BRÜT sertifika kullanılmaz:
 * ikinci hakedişten itibaren kalanı şişirirdi. Fazla ödemede negatif.
 */
export function claimUnpaidRemainder(
  claim: Pick<ProgressClaim, "id" | "net_payable">,
  payments: readonly SubcontractPayment[]
): number {
  return round2(claim.net_payable - paidAgainstClaim(payments, claim.id));
}

// ---------------------------------------------------------------------------
// Form taslakları -> istek gövdesi
// ---------------------------------------------------------------------------

// Boş -> null, okunamayan -> "invalid". parseAmountTR eksi işareti tanımaz;
// "-5" "geçersiz" yerine "negatif" hatası versin diye işaret burada ayrılır.
function parseOptionalAmount(raw: string): number | null | "invalid" {
  const s = raw.trim();
  if (s === "") return null;
  const negative = s.startsWith("-");
  const n = parseAmountTR(negative ? s.slice(1) : s);
  if (!Number.isFinite(n)) return "invalid";
  return negative ? -n : n;
}

/** SOV kalemi taslağı (form state'i). Tutarlar Türkçe yazılabilir ("1.250,50"). */
export interface SovDraft {
  description: string;
  cost_code_id: string;
  budget_line_id: string;
  wbs_node_id: string;
  quantity: string;
  unit: string;
  unit_price: string;
  amount: string;
}

export function emptySovDraft(): SovDraft {
  return {
    description: "",
    cost_code_id: "",
    budget_line_id: "",
    wbs_node_id: "",
    quantity: "",
    unit: "",
    unit_price: "",
    amount: "",
  };
}

function numberText(n: number | null | undefined): string {
  return n === null || n === undefined ? "" : String(n);
}

/**
 * Mevcut kalemden taslak. PUT kalemleri BÜTÜNÜYLE yeniden yazdığı için
 * WBS/bütçe kalemi/miktar/birim fiyat dahil her alan korunur (gönderilmezse
 * sessizce silinirdi).
 */
export function sovDraftFromItem(it: SubcontractItem): SovDraft {
  return {
    description: it.description,
    cost_code_id: it.cost_code_id,
    budget_line_id: it.budget_line_id ?? "",
    wbs_node_id: it.wbs_node_id ?? "",
    quantity: numberText(it.quantity),
    unit: it.unit ?? "",
    unit_price: numberText(it.unit_price),
    amount: numberText(it.original_amount),
  };
}

export function sovDraftIsBlank(d: SovDraft): boolean {
  return (
    d.description.trim() === "" &&
    d.cost_code_id === "" &&
    d.amount.trim() === "" &&
    d.quantity.trim() === "" &&
    d.unit_price.trim() === ""
  );
}

/**
 * Kalemin etkin tutarı: miktar VE birim fiyat ikisi de doluysa
 * round(miktar × birim fiyat, 2) (backend SQL'de aynısını yeniden hesaplar),
 * aksi halde girilen tutar. Geçersizse NaN.
 */
export function sovDraftAmount(d: SovDraft): number {
  const q = parseOptionalAmount(d.quantity);
  const p = parseOptionalAmount(d.unit_price);
  if (q === "invalid" || p === "invalid") return NaN;
  if (q !== null && p !== null) return round2(q * p);
  const a = parseOptionalAmount(d.amount);
  return a === null || a === "invalid" ? NaN : a;
}

export interface SovItemPayload {
  wbs_node_id: string;
  cost_code_id: string;
  budget_line_id: string;
  description: string;
  quantity: number | null;
  unit: string;
  unit_price: number | null;
  original_amount: number;
}

/**
 * Taslaklardan `items` gövdesi. Hiç dokunulmamış satır atlanır; yarım ya da
 * geçersiz satır kendi hatasını döndürür (mobil formdaki gibi sessizce
 * atlanmaz). errors: satır sırası -> mesaj.
 */
export function buildSovItems(drafts: readonly SovDraft[]): { items: SovItemPayload[]; errors: Record<number, string> } {
  const items: SovItemPayload[] = [];
  const errors: Record<number, string> = {};
  drafts.forEach((d, i) => {
    if (sovDraftIsBlank(d)) return;
    const q = parseOptionalAmount(d.quantity);
    const p = parseOptionalAmount(d.unit_price);
    if (d.cost_code_id === "") errors[i] = "Maliyet kodu seçin.";
    else if (d.description.trim() === "") errors[i] = "Açıklama gerekli.";
    else if (q === "invalid" || (q !== null && q <= 0)) errors[i] = "Miktar geçersiz.";
    else if (p === "invalid" || (p !== null && p < 0)) errors[i] = "Birim fiyat geçersiz.";
    else {
      const amount = sovDraftAmount(d);
      if (!Number.isFinite(amount) || amount <= 0) errors[i] = "Tutar 0'dan büyük olmalı.";
      else
        items.push({
          wbs_node_id: d.wbs_node_id,
          cost_code_id: d.cost_code_id,
          budget_line_id: d.budget_line_id,
          description: d.description.trim(),
          quantity: q,
          unit: d.unit.trim(),
          unit_price: p,
          original_amount: amount,
        });
    }
  });
  return { items, errors };
}

/** Değişiklik emri kalemi taslağı. */
export interface ChangeItemDraft {
  description: string;
  cost_code_id: string;
  budget_line_id: string;
  wbs_node_id: string;
  amount: string;
}

export function emptyChangeItemDraft(): ChangeItemDraft {
  return { description: "", cost_code_id: "", budget_line_id: "", wbs_node_id: "", amount: "" };
}

export function changeItemDraftFromItem(it: SubcontractChangeOrderItem): ChangeItemDraft {
  return {
    description: it.description,
    cost_code_id: it.cost_code_id,
    budget_line_id: it.budget_line_id ?? "",
    wbs_node_id: it.wbs_node_id ?? "",
    amount: numberText(it.amount),
  };
}

export interface ChangeItemPayload {
  wbs_node_id: string;
  cost_code_id: string;
  budget_line_id: string;
  description: string;
  amount: number;
}

export function buildChangeItems(drafts: readonly ChangeItemDraft[]): {
  items: ChangeItemPayload[];
  errors: Record<number, string>;
} {
  const items: ChangeItemPayload[] = [];
  const errors: Record<number, string> = {};
  drafts.forEach((d, i) => {
    if (d.description.trim() === "" && d.cost_code_id === "" && d.amount.trim() === "") return;
    const amount = parseOptionalAmount(d.amount);
    if (d.cost_code_id === "") errors[i] = "Maliyet kodu seçin.";
    else if (d.description.trim() === "") errors[i] = "Açıklama gerekli.";
    else if (amount === null || amount === "invalid" || amount <= 0) errors[i] = "Tutar 0'dan büyük olmalı.";
    else
      items.push({
        wbs_node_id: d.wbs_node_id,
        cost_code_id: d.cost_code_id,
        budget_line_id: d.budget_line_id,
        description: d.description.trim(),
        amount,
      });
  });
  return { items, errors };
}

/**
 * Hakediş kalemleri: SOV kalemi id -> "bu dönem" metni. Boş satır hakedişe
 * girmez; 0 girilebilir (mobil gibi), negatif olamaz. Aynı SOV kalemi tek
 * satırdır (backend ErrProgressClaimDuplicateItem bu yapıda oluşamaz).
 */
export function buildClaimItems(
  sovItemIds: readonly string[],
  entries: Readonly<Record<string, string>>
): { items: { subcontract_item_id: string; current_progress_amount: number }[]; errors: Record<string, string> } {
  const items: { subcontract_item_id: string; current_progress_amount: number }[] = [];
  const errors: Record<string, string> = {};
  for (const id of sovItemIds) {
    const raw = entries[id] ?? "";
    const v = parseOptionalAmount(raw);
    if (v === null) continue;
    if (v === "invalid") errors[id] = "Geçerli bir tutar girin.";
    else if (v < 0) errors[id] = "Negatif olamaz.";
    else items.push({ subcontract_item_id: id, current_progress_amount: v });
  }
  return { items, errors };
}

/** Hakediş tutarı metinlerini sayıya çevirir (boş ve geçersizler hariç). */
export function claimEntryAmounts(entries: Readonly<Record<string, string>>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [id, raw] of Object.entries(entries)) {
    const v = parseOptionalAmount(raw);
    if (typeof v === "number" && v >= 0) out[id] = v;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Hakediş önizlemesi ve sınırları
// ---------------------------------------------------------------------------

export interface ClaimPreview {
  gross: number;
  retention: number;
  advance: number;
  other: number;
  net: number;
}

/**
 * Net Hakediş = Brüt − Teminat Kesintisi − Avans Mahsubu − Diğer Kesintiler;
 * Teminat = round(Brüt × % / 100, 2) (docs/subcontracts.md §7.3). Yalnızca
 * ÖNİZLEMEDİR -- kayıttaki rakamları backend hesaplar.
 */
export function claimPreview(input: {
  amounts: readonly number[];
  retentionPercent: number;
  advanceRecovery: number;
  otherDeductions: number;
}): ClaimPreview {
  const gross = round2(input.amounts.reduce((s, a) => s + a, 0));
  const retention = round2((gross * (input.retentionPercent || 0)) / 100);
  const advance = round2(input.advanceRecovery || 0);
  const other = round2(input.otherDeductions || 0);
  return { gross, retention, advance, other, net: round2(gross - retention - advance - other) };
}

/** Sınır grubunun anahtarı -- backend capGroupKey ile aynı: (maliyet kodu, bütçe kalemi). */
export function capGroupKey(costCodeId: string, budgetLineId?: string | null): string {
  return `${costCodeId}|${budgetLineId ?? ""}`;
}

/**
 * Onaylı değişiklik emirlerinin (maliyet kodu, bütçe kalemi) grubu başına
 * NET etkisi (ek iş +, kesinti −). Onaylı olmayanlar sayılmaz.
 */
export function approvedChangeNetByGroup(
  changeOrders: readonly {
    status: string;
    change_type: SubcontractChangeType;
    items: readonly Pick<SubcontractChangeOrderItem, "cost_code_id" | "budget_line_id" | "amount">[];
  }[]
): Record<string, number> {
  const out: Record<string, number> = {};
  for (const co of changeOrders) {
    if (co.status !== "approved") continue;
    const sign = co.change_type === "deduction" ? -1 : 1;
    for (const it of co.items) {
      const k = capGroupKey(it.cost_code_id, it.budget_line_id);
      out[k] = round2((out[k] ?? 0) + sign * it.amount);
    }
  }
  return out;
}

/**
 * SOV kalemi başına en son SERTİFİKALI kümülatif ("önceki"). Sertifikalı
 * zincirde kümülatif hiç azalmaz (her hakediş ≥ 0 ekler, sertifika anında
 * taban kayması reddedilir) -- bu yüzden en büyük değer en son değerdir.
 * Taslak/gönderilmiş/reddedilmiş/iptal hakedişler sayılmaz.
 */
export function latestCertifiedCumulative(
  claims: readonly {
    id: string;
    status: string;
    items: readonly Pick<ProgressClaimItem, "subcontract_item_id" | "cumulative_progress_amount">[];
  }[],
  excludeClaimId?: string | null
): Record<string, number> {
  const out: Record<string, number> = {};
  for (const c of claims) {
    if (c.status !== "certified" || c.id === excludeClaimId) continue;
    for (const it of c.items) {
      const prev = out[it.subcontract_item_id] ?? 0;
      if (it.cumulative_progress_amount > prev) out[it.subcontract_item_id] = it.cumulative_progress_amount;
    }
  }
  return out;
}

export interface ClaimCapRow {
  /** Kalemin asıl (SOV) tutarı. */
  scheduled: number;
  /** Kümülatif sınırı: kalem tutarı + grubun onaylı NET eki (pozitifse). */
  cap: number;
  /** En son sertifikalı kümülatif. */
  previous: number;
  /** Bu hakedişteki tutar (hakedişte yoksa null). */
  current: number | null;
  /** previous + current (hakedişte yoksa previous). */
  cumulative: number;
  /** cap − cumulative (negatifse aşım). */
  remaining: number;
  over: boolean;
}

export interface ClaimCapIssue {
  kind: "item" | "group" | "contract";
  /** item: SOV kalemi id; group: grup anahtarı; contract: "". */
  key: string;
  limit: number;
  cumulative: number;
}

/**
 * Backend subcontract_claim_caps.go kurallarının istemci önizlemesi:
 *   - kalem:    kümülatif ≤ kalem tutarı + grubun onaylı NET eki (pozitifse)
 *   - grup:     gruptaki kalemlerin kümülatif toplamı ≤ grubun SOV toplamı +
 *               grubun onaylı net değişikliği (YALNIZCA hakedişin dokunduğu
 *               gruplar)
 *   - sözleşme: tüm kalemlerin kümülatif toplamı ≤ güncel sözleşme tutarı
 * "Kümülatif" hakedişteki kalemler için önceki + bu dönem, diğerleri için en
 * son sertifikalı değerdir. Uyarı amaçlıdır; kesin karar ve 409 mesajı
 * sunucudandır.
 */
export function claimCapCheck(input: {
  sovItems: readonly Pick<SubcontractItem, "id" | "cost_code_id" | "budget_line_id" | "original_amount">[];
  changeNetByGroup: Readonly<Record<string, number>>;
  certified: Readonly<Record<string, number>>;
  currentValue: number;
  entries: Readonly<Record<string, number>>;
}): { rows: Record<string, ClaimCapRow>; issues: ClaimCapIssue[] } {
  const rows: Record<string, ClaimCapRow> = {};
  const issues: ClaimCapIssue[] = [];
  const groupSOV: Record<string, number> = {};
  const groupCum: Record<string, number> = {};
  const touched = new Set<string>();
  let total = 0;

  for (const it of input.sovItems) {
    const k = capGroupKey(it.cost_code_id, it.budget_line_id);
    groupSOV[k] = round2((groupSOV[k] ?? 0) + it.original_amount);
  }
  for (const it of input.sovItems) {
    const k = capGroupKey(it.cost_code_id, it.budget_line_id);
    const add = Math.max(0, input.changeNetByGroup[k] ?? 0);
    const cap = round2(it.original_amount + add);
    const previous = input.certified[it.id] ?? 0;
    const current = it.id in input.entries ? input.entries[it.id] : null;
    const cumulative = round2(previous + (current ?? 0));
    const over = current !== null && cents(cumulative) > cents(cap);
    rows[it.id] = { scheduled: it.original_amount, cap, previous, current, cumulative, remaining: round2(cap - cumulative), over };
    if (over) issues.push({ kind: "item", key: it.id, limit: cap, cumulative });
    if (current !== null) touched.add(k);
    groupCum[k] = round2((groupCum[k] ?? 0) + cumulative);
    total = round2(total + cumulative);
  }
  for (const k of touched) {
    const limit = round2((groupSOV[k] ?? 0) + (input.changeNetByGroup[k] ?? 0));
    if (cents(groupCum[k] ?? 0) > cents(limit)) issues.push({ kind: "group", key: k, limit, cumulative: groupCum[k] ?? 0 });
  }
  if (touched.size > 0 && cents(total) > cents(input.currentValue)) {
    issues.push({ kind: "contract", key: "", limit: input.currentValue, cumulative: total });
  }
  return { rows, issues };
}

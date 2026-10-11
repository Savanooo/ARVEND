// Bütçe revizyonu ve ek iş (müşteri kararı) onaylarının saf yardımcıları --
// Maliyet Kontrolü > Bütçe Revizyonları ve Finans > Ek İşler kullanır, node
// testleri (approvals.test.mts) içe aktarır. Kurallar mobil
// budget_adjustments_screen.dart ve change_order_detail_screen.dart ile,
// sunucu tarafı ise router.go + service katmanıyla aynıdır; buradaki gizleme
// yalnızca UX'tir, asıl sınır backend'dir (409/403 mesajı olduğu gibi
// gösterilir).
import type { AdjustmentStatus, ChangeOrder, ChangeOrderStatus, User } from "./types";

// ---------- Kim ----------

/**
 * Firma Sahibi mi (organizasyon rolü "owner"). Tek onaylayıcısı olan küçük
 * firma kilitlenmesin diye backend Sahip'in kendi bütçe revizyonuna karar
 * vermesine izin verir; istemci de aynı istisnayı uygular.
 */
export function isOrgOwner(user: Pick<User, "organization_role_code"> | null | undefined): boolean {
  return user?.organization_role_code === "owner";
}

// ---------- Bütçe revizyonu ----------

/** Rol ekranındaki izin adı (migration 0062) -- mobil kBudgetApprovePermissionLabel. */
export const BUDGET_APPROVE_PERMISSION_LABEL = "Bütçe revizyonunu onaylama/reddetme";

/** Kişinin kendi bekleyen revizyonu (Sahip değilse): dört göz ilkesi. */
export const OWN_ADJUSTMENT_TEXT = "Bu revizyonu sen oluşturdun; başka bir yetkilinin onaylaması gerekir.";

/** Onay izni olmayan kişi bekleyen revizyon gördüğünde: düğmelerin neden olmadığı. */
export const ADJUSTMENT_APPROVE_MISSING_TEXT = `Onaylamak veya reddetmek için rolünde "${BUDGET_APPROVE_PERMISSION_LABEL}" izni olmalı.`;

interface AdjustmentLike {
  status: AdjustmentStatus;
  created_by?: string | null;
}

/**
 * Bir revizyon satırında ne gösterilir:
 * - "decide": Onayla / Reddet düğmeleri,
 * - "own": düğmeler yerine OWN_ADJUSTMENT_TEXT (kişinin kendi revizyonu, Sahip değil),
 * - "none": hiçbiri (karara bağlanmış, proje kapalı ya da projects.budget.approve yok).
 *
 * Yalnızca "draft" (= onay bekliyor) karara bağlanabilir; sunucu diğerlerinde
 * 409 döner.
 */
export type AdjustmentDecisionUI = "decide" | "own" | "none";

export function adjustmentDecisionUI(
  a: AdjustmentLike,
  viewer: { canApprove: boolean; locked: boolean; userId: string | null | undefined; isOwner: boolean }
): AdjustmentDecisionUI {
  if (a.status !== "draft" || viewer.locked || !viewer.canApprove) return "none";
  const own = Boolean(viewer.userId) && a.created_by === viewer.userId;
  return own && !viewer.isOwner ? "own" : "decide";
}

/** "3 revizyon · 1 onay bekliyor" başlığı için sayılar. */
export function adjustmentCounts(adjustments: readonly AdjustmentLike[]): { total: number; pending: number } {
  return { total: adjustments.length, pending: adjustments.filter((a) => a.status === "draft").length };
}

// ---------- Ek iş: müşteri kararını personelin kaydetmesi ----------

/** record-decision gövdesindeki karar (backend domain.ChangeOrderApproved/Rejected). */
export type ChangeOrderDecision = "approved" | "rejected";

/** decision_note sütun sınırı (migration 0063, service maxChangeOrderDecisionNoteRunes). */
export const CHANGE_ORDER_DECISION_NOTE_MAX = 500;

/**
 * projects.finance.manage olmayan kişi (açık projede): oluştur/gönder/iptal
 * düğmelerinin neden olmadığı -- mobil kChangeOrdersReadOnlyText ile aynı.
 */
export const CHANGE_ORDERS_READ_ONLY_TEXT =
  "Ek işleri yalnızca görüntüleyebilirsin; oluşturmak, göndermek veya iptal etmek için rolünde " +
  '"Proje finansal işlemlerini yönetme" izni olmalı.';

/**
 * "Müşteri onayladı / reddetti olarak işaretle" görünür mü: yalnızca
 * GÖNDERİLMİŞ ek işte, projects.change_orders.approve ile, açık projede
 * (sunucu diğer durumlarda 409 döner).
 */
export function canRecordChangeOrderDecision(
  co: { status: ChangeOrderStatus },
  viewer: { canRecord: boolean; locked: boolean }
): boolean {
  return co.status === "sent" && viewer.canRecord && !viewer.locked;
}

/**
 * Kararı müşteri linkten değil ekip kaydettiyse kim ve hangi notla
 * (mobil _recordedLines ile aynı metin). Müşterinin kendi linkinden gelen
 * kararda decision_recorded_by null'dır -- satır yok.
 */
export function changeOrderDecisionLines(
  co: Pick<ChangeOrder, "decision_recorded_by" | "decision_recorded_by_name" | "decision_note">
): string[] {
  const lines: string[] = [];
  if (co.decision_recorded_by) {
    const name = co.decision_recorded_by_name?.trim();
    lines.push(name ? `Müşterinin yanıtını ${name} kaydetti.` : "Müşterinin yanıtını ekip kaydetti.");
  }
  const note = co.decision_note?.trim();
  if (note) lines.push(`Not: ${note}`);
  return lines;
}

/** Karar penceresinin metinleri (mobil _recordDecision ile aynı). effect: "+15.000,00 TL" gibi işaretli tutar. */
export function recordDecisionDialog(
  co: Pick<ChangeOrder, "change_order_no">,
  decision: ChangeOrderDecision,
  effect: string
): { title: string; message: string; confirmLabel: string; placeholder: string; success: string; danger: boolean } {
  if (decision === "approved") {
    return {
      title: "Müşteri Onayını Kaydet",
      message:
        `${co.change_order_no} müşteri tarafından onaylandı olarak işaretlensin mi? Sonuç müşterinin linkten ` +
        `onaylamasıyla aynıdır: ek iş kesinleşir ve proje bedeli ${effect} değişir. Bu işlem geri alınamaz.`,
      confirmLabel: "Onaylandı Olarak İşaretle",
      placeholder: "ör. telefonla onay",
      success: `${co.change_order_no} müşteri onayladı olarak işaretlendi.`,
      danger: false,
    };
  }
  return {
    title: "Müşteri Reddini Kaydet",
    message:
      `${co.change_order_no} müşteri tarafından reddedildi olarak işaretlensin mi? Proje bedeli değişmez; ` +
      "gerekirse revize ederek yeni bir taslak açabilirsin.",
    confirmLabel: "Reddedildi Olarak İşaretle",
    placeholder: "ör. müşteri yazılı olarak reddetti",
    success: `${co.change_order_no} müşteri reddetti olarak işaretlendi.`,
    danger: true,
  };
}

// ---------- Maliyet Kontrolü alt sekmesi (bildirim derin bağlantısı) ----------

export type CostTab = "ozet" | "butce" | "taahhutler" | "gerceklesen" | "tahmin";

export const COST_TABS: readonly CostTab[] = ["ozet", "butce", "taahhutler", "gerceklesen", "tahmin"];

/**
 * Proje detayının ?alt= değeri -> Maliyet Kontrolü alt sekmesi; bilinmeyen
 * ya da boş "ozet". Bütçe revizyonu bildirimi ?tab=maliyet&alt=butce açar
 * (bkz. webHrefForActionTarget).
 */
export function parseCostTab(raw: string | null | undefined): CostTab {
  return COST_TABS.includes(raw as CostTab) ? (raw as CostTab) : "ozet";
}

/** "Bütçe Revizyonları" başlığının çapası (bildirim bağlantısı oraya kaydırır). */
export const BUDGET_ADJUSTMENTS_ANCHOR = "butce-revizyonlari";

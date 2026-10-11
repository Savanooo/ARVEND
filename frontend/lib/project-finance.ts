// Proje para alanlarının finans iznine bağlı gösterimi -- saf yardımcılar
// (next/* ya da React içermez; node testleri içe aktarır).
//
// Backend projects.finance.read izni olmayana (Saha, Proje Yöneticisi,
// izni kişiye özel kaldırılmış kişi): proje yanıtında contract_amount'u null
// döner, liste aggregate'lerini (tahsilat, bakiye, masraf, kâr, fatura
// sayıları, ek iş, güncel bedel) hiç göndermez, olay metadata'sından
// tutarları ve maliyet kontrolü özetinden sözleşme bedeli / tahmini kâr /
// marjı düşürür (bkz. backend/docs/authorization.md §11). Ekranlar izne
// göre sütun/kart gizler; yine de null gelirse "—" yazılır -- asla 0 ya da
// NaN değil. Mobil aynı kuralı uygular.
import { formatMoney } from "./format.ts";
import { hasPermission } from "./permissions.ts";

export const PROJECT_FINANCE_READ = "projects.finance.read";

/** Gösterilmeyen/olmayan tutarın yerine yazılan metin. */
export const NO_MONEY = "—";

/** Kullanıcı proje para bilgisini görebilir mi (efektif izin kümesi, /auth/me). */
export function canSeeProjectFinance(permissions: readonly string[] | undefined): boolean {
  return hasPermission(permissions, PROJECT_FINANCE_READ);
}

/** Gösterilebilir bir tutar mı (null/undefined/NaN/Infinity değil). */
export function isMoney(value: number | null | undefined): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

/** Tutar varsa biçimlendirir, yoksa "—". */
export function formatOptionalMoney(value: number | null | undefined, currency = "TRY"): string {
  return isMoney(value) ? formatMoney(value, currency) : NO_MONEY;
}

// Mesai girişinin saf yardımcıları -- mobil ile AYNI kural
// (mobile/lib/features/attendance/domain/attendance_entry.dart).
import type { AttendanceStatus } from "./types";

/** Mobil formun varsayılan giriş/çıkış saatleri. */
export const DEFAULT_CHECK_IN = "08:00";
export const DEFAULT_CHECK_OUT = "17:00";

function minutesOf(hm: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hm.trim());
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

/**
 * "08:00" - "17:00" -> 9 (düz fark, mola düşülmez -- mobil ve eski BYZ ile
 * aynı). Geçersizse ya da çıkış girişten önce/aynıysa null. İki ondalığa
 * yuvarlanır.
 */
export function hoursBetween(checkIn: string, checkOut: string): number | null {
  const a = minutesOf(checkIn);
  const b = minutesOf(checkOut);
  if (a === null || b === null || b <= a) return null;
  return Math.round(((b - a) / 60) * 100) / 100;
}

/** Gelmedi/izinli günde saat ve giriş-çıkış anlamsız: 0 ve boş gönderilir. */
export function statusHasHours(status: AttendanceStatus): boolean {
  return status === "geldi" || status === "yarım gün";
}

/**
 * Formdaki giriş/çıkış/saat üçlüsü. hoursEdited: kullanıcı saati elle
 * değiştirdiyse giriş/çıkış değişince üzerine yazılmaz (mobil ile aynı).
 */
export interface AttendanceTimes {
  check_in: string;
  check_out: string;
  work_hours: string;
  hoursEdited: boolean;
}

export function initialTimes(existing?: { check_in: string; check_out: string; work_hours: number }): AttendanceTimes {
  const checkIn = existing?.check_in || DEFAULT_CHECK_IN;
  const checkOut = existing?.check_out || DEFAULT_CHECK_OUT;
  const hours = existing ? existing.work_hours : (hoursBetween(checkIn, checkOut) ?? 8);
  return { check_in: checkIn, check_out: checkOut, work_hours: String(hours), hoursEdited: false };
}

/** Giriş ya da çıkış değişti: saat elle düzenlenmediyse yeniden hesaplanır. */
export function withTimeChange(times: AttendanceTimes, patch: { check_in?: string; check_out?: string }): AttendanceTimes {
  const next = { ...times, ...patch };
  const h = hoursBetween(next.check_in, next.check_out);
  if (h !== null && !times.hoursEdited) next.work_hours = String(h);
  return next;
}

/**
 * Gönderilecek saat. Saat kutusu boşsa giriş-çıkıştan hesaplanır (eskiden
 * web 08:00-17:00 + boş kutu ile 0 saat kaydediyordu); Türkçe ondalık
 * virgülü kabul edilir. Geçersizse NaN.
 */
export function resolveWorkHours(times: AttendanceTimes): number {
  const raw = times.work_hours.trim().replace(",", ".");
  if (raw === "") return hoursBetween(times.check_in, times.check_out) ?? 0;
  return Number(raw);
}

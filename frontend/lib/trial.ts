import { formatDateTR, istanbulDate } from "./format.ts";
import type { Tone } from "@/components/ui/Badge";
import type { Organization, User } from "./types";

/*
 * Deneme süresi (ürün kararı 2026-10-07): süre dolunca erişim OTOMATİK
 * KESİLMEZ -- bu yalnızca bir hatırlatmadır; kesmek Süper Admin'in firma
 * durumunu değiştirmesidir. Mobil karşılığı:
 * mobile/lib/features/dashboard/domain/trial_notice.dart (aynı kural, aynı
 * metinler -- web = mobil).
 */

/** Uyarının gösterileceği son gün sayısı (bitişe bu kadar ya da daha az). */
export const TRIAL_NOTICE_DAYS = 7;

export interface TrialNotice {
  expired: boolean;
  text: string;
}

type TrialUser = Pick<
  User,
  "organization_role_code" | "organization_status" | "trial_ends_on" | "trial_days_left" | "trial_expired"
>;

/**
 * Firma Sahibi/Yöneticisine gösterilecek uyarı; yoksa null. Kalan gün ve
 * "doldu mu" oturumdan (/auth/me) gelir -- İstanbul günü, sunucu hesaplar
 * (backend domain.Organization.Trial); burada tarih hesabı yapılmaz.
 * Diğer roller hiçbir şey görmez (ödeme/sözleşme kararı Sahip/Yönetici'nin).
 */
export function trialNoticeFor(user: TrialUser | null | undefined): TrialNotice | null {
  if (!user || user.organization_status !== "trial") return null;
  if (user.organization_role_code !== "owner" && user.organization_role_code !== "admin") return null;
  const days = user.trial_days_left;
  if (days == null) return null;
  if (user.trial_expired) {
    const endsOn = user.trial_ends_on ? ` ${formatDateTR(user.trial_ends_on)} tarihinde` : "";
    return {
      expired: true,
      text: `Deneme süreniz${endsOn} bitti. Devam etmek için ARVEND ile iletişime geçin.`,
    };
  }
  if (days > TRIAL_NOTICE_DAYS) return null;
  return {
    expired: false,
    text: days <= 0 ? "Deneme süreniz bugün bitiyor." : `Deneme süreniz ${days} gün sonra bitiyor.`,
  };
}

/**
 * "Bugün için kapat" tercihinin localStorage anahtarı -- kişiye ve firmaya
 * özel (mobil SharedPreferences anahtarıyla aynı ad); değer kapatıldığı
 * İSTANBUL günüdür ("YYYY-MM-DD"). Ertesi gün uyarı yeniden çıkar.
 */
export function trialNoticeDismissKey(organizationId: string, userId: string): string {
  return `arvend.home.trial_notice.dismissed.${organizationId}.${userId}`;
}

/** Kapatma yalnızca kapatıldığı İstanbul günü için geçerlidir. */
export function trialNoticeDismissedToday(storedDay: string | null, now: Date): boolean {
  return storedDay !== null && storedDay === istanbulDate(now);
}

export interface TrialBadge {
  label: string;
  tone: Tone;
  /** Kalan gün (İstanbul günü): bitiş günü 0, geçtiyse negatif. */
  daysLeft: number;
  /** Bitişin İstanbul takvim günü ("YYYY-MM-DD"). */
  endsOn: string;
}

/**
 * Süper Admin firma listesindeki deneme rozeti. Platform firma yanıtında
 * yalnızca trial_ends_at (an) var; kalan gün oturumdaki kuralla AYNI
 * hesaplanır: bitiş anının İstanbul günü - bugünün İstanbul günü (bitiş
 * günü boyunca deneme sürer, "bugün bitiyor"). Deneme dışındaki ya da
 * bitiş tarihi kayıtlı olmayan firmada null.
 */
export function orgTrialBadge(
  org: Pick<Organization, "status" | "trial_ends_at">,
  now: Date
): TrialBadge | null {
  if (org.status !== "trial" || !org.trial_ends_at) return null;
  const endsAt = new Date(org.trial_ends_at);
  if (Number.isNaN(endsAt.getTime())) return null;
  const endsOn = istanbulDate(endsAt);
  const daysLeft = dayDiff(istanbulDate(now), endsOn);
  if (daysLeft < 0) return { label: "Deneme bitti", tone: "danger", daysLeft, endsOn };
  if (daysLeft === 0) return { label: "Bugün bitiyor", tone: "gold", daysLeft, endsOn };
  return {
    label: `${daysLeft} gün kaldı`,
    tone: daysLeft <= TRIAL_NOTICE_DAYS ? "gold" : "muted",
    daysLeft,
    endsOn,
  };
}

/** İki "YYYY-MM-DD" günü arasındaki takvim farkı (to - from). */
function dayDiff(from: string, to: string): number {
  const a = Date.UTC(Number(from.slice(0, 4)), Number(from.slice(5, 7)) - 1, Number(from.slice(8, 10)));
  const b = Date.UTC(Number(to.slice(0, 4)), Number(to.slice(5, 7)) - 1, Number(to.slice(8, 10)));
  return Math.round((b - a) / 86_400_000);
}

// Saf biçimlendirme yardımcıları -- next/* ya da React içermez; hem
// Server/Client Component'ler hem node testleri (format.test.mts) içe
// aktarabilir. Saat içeren her biçim Europe/Istanbul'a göredir (sunucu ya
// da tarayıcı saat dilimine ASLA güvenilmez, bkz. ana sayfa spec D20).

export function formatTL(value: number): string {
  return (
    value.toLocaleString("tr-TR", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }) + " TL"
  );
}

const CURRENCY_SUFFIX: Record<string, string> = { TRY: "TL", USD: "$", EUR: "€" };

/** Para biriminin görünen eki: TRY -> "TL", USD -> "$", bilinmeyen -> kodun kendisi. */
export function currencySuffix(currency: string): string {
  return CURRENCY_SUFFIX[currency] ?? currency;
}

// formatMoney, tutarı projenin para birimine göre biçimler -- finans
// ekranlarında her zaman bu kullanılmalı (formatTL yalnızca TL'ye sabittir).
export function formatMoney(value: number, currency = "TRY"): string {
  const amount = value.toLocaleString("tr-TR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return `${amount} ${currencySuffix(currency)}`;
}

// formatSignedMoney, ek iş/eksiltmenin ticari etkisini açıkça +/- işaretli
// gösterir -- renge tek başına güvenilmemeli (bkz. Faz 8 UI kuralı).
export function formatSignedMoney(value: number, currency = "TRY"): string {
  const sign = value > 0 ? "+" : value < 0 ? "-" : "";
  return `${sign}${formatMoney(Math.abs(value), currency)}`;
}

/** Tam sayı, Türkçe binlik ayırıcıyla: 4393 -> "4.393". */
export function formatCount(value: number): string {
  return Math.round(value).toLocaleString("tr-TR", { maximumFractionDigits: 0 });
}

function oneDecimal(value: number): string {
  return value.toLocaleString("tr-TR", { maximumFractionDigits: 1 });
}

/**
 * Kısa sayı (ana sayfa spec D5), para eki OLMADAN -- grafik eksen
 * etiketleri bunu kullanır. 1.000.000 altı: tam sayı, binlik ayırıcılı
 * ("850.000"); 1.000.000 ve üstü: tek ondalık + "Mn" ("12,5 Mn", sondaki
 * ",0" atılır: "12 Mn"); 1.000.000.000 ve üstü: "Mr". "B"/"Bin" ASLA
 * kullanılmaz. Yuvarlama bir üst basamağa taşarsa (999.999,6 -> "1 Mn",
 * 999,96 Mn -> "1 Mr") üst birime geçilir.
 */
export function formatCompactNumber(value: number): string {
  const abs = Math.abs(value);
  const whole = Math.round(abs);
  if (whole < 1_000_000) {
    return `${value < 0 && whole > 0 ? "-" : ""}${formatCount(whole)}`;
  }
  const sign = value < 0 ? "-" : "";
  const millions = Math.round(abs / 100_000) / 10;
  if (millions < 1000) return `${sign}${oneDecimal(millions)} Mn`;
  const billions = Math.round(abs / 100_000_000) / 10;
  return `${sign}${oneDecimal(billions)} Mr`;
}

/** Kısa para (D5): "850.000 TL", "12,5 Mn TL", "1,3 Mr TL", "45.000 $". */
export function formatCompactMoney(value: number, currency = "TRY"): string {
  return `${formatCompactNumber(value)} ${currencySuffix(currency)}`;
}

/** İşaretli kısa para: "+420.000 TL" / "-1,2 Mn TL"; sıfır işaretsizdir. */
export function formatSignedCompactMoney(value: number, currency = "TRY"): string {
  const rounded = Math.round(Math.abs(value));
  const sign = rounded === 0 ? "" : value > 0 ? "+" : "-";
  return `${sign}${formatCompactMoney(Math.abs(value), currency)}`;
}

/** Türkçe yüzde yazımı: 15 -> "%15", 12.5 -> "%12,5" (binlik ayırıcısız, en çok 2 ondalık). */
export function formatPercent(value: number): string {
  return `%${value.toLocaleString("tr-TR", { useGrouping: false, maximumFractionDigits: 2 })}`;
}

/** Saat toplamı: 4120.5 -> "4.120,5 sa". */
export function formatHours(value: number): string {
  return `${oneDecimal(value)} sa`;
}

/** Gün sayısı: 21 -> "21 gün". */
export function formatAgeDays(days: number): string {
  return `${formatCount(days)} gün`;
}

// ---------------------------------------------------------------------------
// Tarih/saat (Europe/Istanbul)
// ---------------------------------------------------------------------------

export const ISTANBUL_TZ = "Europe/Istanbul";

// Ay/gün adları bilinçli olarak elle yazılır: çıktı ICU sürümüne bağlı
// olmasın, sunucu ve tarayıcı AYNI metni üretsin (hydration uyuşmazlığı yok).
export const MONTHS_LONG = [
  "Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran",
  "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık",
] as const;
export const MONTHS_SHORT = ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"] as const;
const WEEKDAYS = ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"] as const;

const istanbulPartsFormat = new Intl.DateTimeFormat("en-GB", {
  timeZone: ISTANBUL_TZ,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

interface IstanbulParts {
  day: string; // "YYYY-MM-DD"
  dd: string;
  mm: string;
  yyyy: string;
  hm: string; // "HH:mm"
}

function istanbulParts(at: Date): IstanbulParts {
  const p: Record<string, string> = {};
  for (const part of istanbulPartsFormat.formatToParts(at)) p[part.type] = part.value;
  const hour = p.hour === "24" ? "00" : p.hour;
  return {
    day: `${p.year}-${p.month}-${p.day}`,
    dd: p.day,
    mm: p.month,
    yyyy: p.year,
    hm: `${hour}:${p.minute}`,
  };
}

/** Bir anın İstanbul takvim günü ("YYYY-MM-DD"). */
export function istanbulDate(at: Date): string {
  return istanbulParts(at).day;
}

const DAY_RE = /^(\d{4})-(\d{2})-(\d{2})/;

function parseDay(iso: string): { y: number; m: number; d: number } | null {
  const match = DAY_RE.exec(iso);
  if (!match) return null;
  return { y: Number(match[1]), m: Number(match[2]), d: Number(match[3]) };
}

/** "YYYY-MM-DD" + n gün (takvim aritmetiği, saat dilimi yok). */
export function shiftDay(iso: string, days: number): string {
  const p = parseDay(iso);
  if (!p) return iso;
  const t = new Date(Date.UTC(p.y, p.m - 1, p.d + days));
  return t.toISOString().slice(0, 10);
}

/** "2026-09-28" -> "28 Eylül 2026, Pazartesi". */
export function formatLongDate(isoDate: string): string {
  const p = parseDay(isoDate);
  if (!p) return isoDate;
  const weekday = WEEKDAYS[new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay()];
  return `${p.d} ${MONTHS_LONG[p.m - 1]} ${p.y}, ${weekday}`;
}

/** "2026-09-30" -> "30 Eyl". */
export function formatShortDate(isoDate: string): string {
  const p = parseDay(isoDate);
  if (!p) return isoDate;
  return `${p.d} ${MONTHS_SHORT[p.m - 1]}`;
}

/** "2026-09-30" -> "30.09.2026". */
export function formatDateTR(isoDate: string): string {
  const p = parseDay(isoDate);
  if (!p) return isoDate;
  return `${String(p.d).padStart(2, "0")}.${String(p.m).padStart(2, "0")}.${p.y}`;
}

/** Zaman damgasının İstanbul saati: "09:41". */
export function formatHm(ts: string): string {
  const t = new Date(ts);
  if (Number.isNaN(t.getTime())) return "";
  return istanbulParts(t).hm;
}

/**
 * Göreli zaman (nowIso'ya göre; ana sayfada sunucunun generated_at'i --
 * cihaz saati kullanılmaz): "az önce", "12 dk önce", "3 sa önce" (aynı
 * gün), "dün 17:40", "27.09 14:05" (aynı yıl), "27.09.2025".
 */
export function formatRelativeTime(ts: string, nowIso: string): string {
  const t = new Date(ts);
  const now = new Date(nowIso);
  if (Number.isNaN(t.getTime()) || Number.isNaN(now.getTime())) return "";
  const diffMs = now.getTime() - t.getTime();
  if (diffMs < 60_000) return "az önce";
  const minutes = Math.floor(diffMs / 60_000);
  if (minutes < 60) return `${minutes} dk önce`;
  const tp = istanbulParts(t);
  const np = istanbulParts(now);
  if (tp.day === np.day) return `${Math.floor(minutes / 60)} sa önce`;
  if (tp.day === shiftDay(np.day, -1)) return `dün ${tp.hm}`;
  if (tp.yyyy === np.yyyy) return `${tp.dd}.${tp.mm} ${tp.hm}`;
  return `${tp.dd}.${tp.mm}.${tp.yyyy}`;
}

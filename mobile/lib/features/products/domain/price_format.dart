import 'package:intl/intl.dart';

/// Ürünler / Fiyat Kaynakları / Zam Geçmişi ekranlarının ortak tarih ve
/// yüzde biçimleri -- web `lib/price-sources.ts` + `lib/price-changes.ts` +
/// `lib/format.ts` ile AYNI metinler. Saat içeren her biçim İstanbul
/// saatiyledir (cihazın saat diliminden bağımsız; Türkiye 2016'dan beri
/// sabit UTC+3, yaz saati yok -- bkz. core Formatters._istanbul).

/// Anın İstanbul duvar saati (alanları İstanbul'a göre, UTC işaretli --
/// yalnızca biçimlemek ve gün hesabı için).
DateTime istanbulWallClock(DateTime instant) => instant.toUtc().add(const Duration(hours: 3));

String _two(int n) => n.toString().padLeft(2, '0');

/// Anın İstanbul takvim günü: 2026-09-26T21:30Z -> "2026-09-27".
String istanbulDay(DateTime instant) {
  final t = istanbulWallClock(instant);
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';
}

final _dayRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Geçerli bir YYYY-AA-GG takvim günü mü? ("2026-02-30" gibi taşan günler
/// ve 0-99 yılları reddedilir -- web isValidDay ile aynı.)
DateTime? parseDay(String day) {
  final m = _dayRe.firstMatch(day);
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (y < 100) return null;
  final t = DateTime.utc(y, mo, d);
  if (t.year != y || t.month != mo || t.day != d) return null;
  return t;
}

bool isValidDay(String day) => parseDay(day) != null;

/// DateTime'ın takvim gününü (saat dilimi yok) YYYY-AA-GG yazar.
String dayOf(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// Takvim günü aritmetiği: addDays("2026-03-01", -1) -> "2026-02-28".
String addDays(String day, int n) {
  final p = parseDay(day);
  if (p == null) return day;
  return dayOf(DateTime.utc(p.year, p.month, p.day + n));
}

/// "2026-09-21" -> "21 Eylül 2026".
String formatDay(String day) {
  final p = parseDay(day);
  return p == null ? day : DateFormat('d MMMM y', 'tr_TR').format(p);
}

String formatDayRange(String from, String to) => from == to ? formatDay(from) : '${formatDay(from)} – ${formatDay(to)}';

/// [formatDayRange]'in dar ekran hali: her tarihin parçaları bölünmez
/// boşlukla bağlanır ("30\u00a0Ağustos\u00a02026 – 28\u00a0Eylül\u00a02026"),
/// satır yalnızca iki tarihin ARASINDAN kırılır -- gün bir satırda, ay/yıl
/// ötekinde kalmaz.
String formatDayRangeNoBreak(String from, String to) {
  String keep(String day) => formatDay(day).replaceAll(' ', '\u00a0');
  return from == to ? keep(from) : '${keep(from)} – ${keep(to)}';
}

DateTime? _parseInstant(String iso) => DateTime.tryParse(iso.trim());

/// Fiyat kaynağının senkron zamanı: "27 Eylül 2026 00:05" (İstanbul).
String formatSyncTime(String iso) {
  final t = _parseInstant(iso);
  return t == null ? iso : DateFormat('d MMMM y HH:mm', 'tr_TR').format(istanbulWallClock(t));
}

/// Liste/geçmiş satırının zamanı: "27.09.2026 00:05" (İstanbul).
String formatChangeTime(String iso) {
  final t = _parseInstant(iso);
  return t == null ? iso : DateFormat('dd.MM.yyyy HH:mm', 'tr_TR').format(istanbulWallClock(t));
}

/// Anın İstanbul günü, uzun ("27 Eylül 2026") -- elle düzenleme olayları
/// gün başına gruplandığı için saat yazılmaz.
String formatInstantDay(String iso) {
  final t = _parseInstant(iso);
  return t == null ? iso : DateFormat('d MMMM y', 'tr_TR').format(istanbulWallClock(t));
}

final _percentFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 0
  ..maximumFractionDigits = 2
  ..turnOffGrouping();

/// Türkçe yüzde, en çok 2 ondalık, binlik ayırıcısız: 12.5 -> "%12,5"
/// (web formatPercent ile aynı; core Formatters.percent 1 ondalıktır).
String formatPricePercent(num value) => '%${_percentFormat.format(value)}';

/// Mesai girişinin saf yardımcıları (form ve toplu giriş).
library;

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// [start]..[end] arasındaki günler (ikisi dahil, sıralı). Pazarlar
/// varsayılan olarak atlanır: şantiyede pazar çalışılmaz, toplu girişte
/// tek tek silmek zorunda kalınmasın. Ters aralık boş liste döner.
List<DateTime> entryDays(DateTime start, DateTime end, {bool skipSundays = true}) {
  final from = DateTime(start.year, start.month, start.day);
  final to = DateTime(end.year, end.month, end.day);
  final out = <DateTime>[];
  for (var d = from; !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 1)) {
    if (skipSundays && d.weekday == DateTime.sunday) continue;
    out.add(d);
  }
  return out;
}

/// "08:00" - "17:00" -> 9.0 (BYZ'deki _compute_hours ile aynı: düz fark,
/// mola düşülmez). Geçersiz ya da çıkış girişten önce/aynıysa null.
double? hoursBetween(String checkIn, String checkOut) {
  int? minutes(String s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return h * 60 + mi;
  }

  final a = minutes(checkIn), b = minutes(checkOut);
  if (a == null || b == null || b <= a) return null;
  return ((b - a) / 60 * 100).round() / 100;
}

/// Gelmedi/izinli günde saat ve giriş-çıkış anlamsız: 0 ve boş gönderilir.
bool statusHasHours(String status) => status == 'geldi' || status == 'yarım gün';

/// Mesai girilebilecek son gün: bugün, İstanbul takvimiyle (Türkiye sabit
/// UTC+3). İleri bir güne girilen "geldi" maaşta çalışılmış gün sayılıyordu;
/// backend artık reddediyor, seçiciler de bugünün ötesini göstermez.
/// Seçicilerin kullandığı yerel gün (saat 00:00) olarak döner.
DateTime attendanceLastDay([DateTime? now]) {
  final t = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 3));
  return DateTime(t.year, t.month, t.day);
}

/// [day] bugünden sonraysa bugüne çeker (ör. ileri bir ayın ekranından
/// açılan form); saatini atar.
DateTime clampToAttendanceDay(DateTime day, [DateTime? now]) {
  final d = DateTime(day.year, day.month, day.day);
  final last = attendanceLastDay(now);
  return d.isAfter(last) ? last : d;
}

/// Çalışma saati girişi: "8", "7,5" (Türkçe klavyede ayraç virgül) ya da
/// "7.5"; 0-24 arası. Başka her şey null -- "8 saat" gibi bir metin
/// eskiden sessizce 0 saat olarak kaydediliyordu.
double? parseWorkHours(String raw) {
  final s = raw.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d{1,2}(\.\d{1,2})?$').hasMatch(s)) return null;
  final v = double.parse(s);
  return v > 24 ? null : v;
}

/// Toplu girişin sonucu: eklenen, zaten kayıtlı olduğu için atlanan
/// (sunucu 409) ve -- yarıda kaldıysa -- ilk hata.
class BulkEntryResult {
  const BulkEntryResult({required this.created, required this.skipped, this.error});
  final int created;
  final int skipped;
  final String? error;

  String get summary => [
        '$created kayıt eklendi',
        if (skipped > 0) '$skipped gün zaten kayıtlıydı, atlandı',
        if (error != null) 'durdu: $error',
      ].join(' · ');
}

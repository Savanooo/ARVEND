/// Planlama/ekip ekranlarının tarih yardımcıları. Backend tarih alanları
/// "YYYY-MM-DD" (saat yok) döner; karşılaştırmalar YALNIZCA gün üzerinden,
/// cihaz saat diliminden bağımsız yapılır (UTC gece yarısı).
library;

/// "2026-09-01" -> DateTime.utc(2026, 9, 1). Boş/geçersiz değer null.
DateTime? parseDay(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// Seçilen tarihi backend'in beklediği "YYYY-MM-DD" biçimine çevirir.
String? formatDay(DateTime? day) {
  if (day == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}';
}

/// Bugünün İSTANBUL günü (Türkiye 2016'dan beri sabit UTC+3, yaz saati
/// yok) -- backend `CURRENT_DATE`'i de İstanbul gününe sabitli (bkz.
/// repository/pool.go). Gecikme hesabı cihazın saat diliminden etkilenmesin.
DateTime istanbulToday([DateTime? now]) {
  final t = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 3));
  return DateTime.utc(t.year, t.month, t.day);
}

/// İki gün arasındaki tam gün farkı (b - a).
int daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

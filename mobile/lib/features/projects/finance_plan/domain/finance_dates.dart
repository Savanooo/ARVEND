import '../../../../core/utils/formatters.dart';

/// Ödeme planı / fatura ekranlarının tarih yardımcıları. Backend tarihleri
/// "YYYY-MM-DD" (date sütunu, saat bileşeni YOK) döner; karşılaştırmalar
/// iki TAKVİM GÜNÜ arasında yapılır -- backend `domain.IsPastDue` ile aynı
/// semantik (vade gününün kendisi henüz gecikmiş sayılmaz).

/// Türkiye 2016'dan beri sabit UTC+3 (yaz saati yok): cihazın saat
/// diliminden BAĞIMSIZ olarak İstanbul'un bugünü (bkz. backend
/// `service.IstanbulNow`). Dönen değer UTC olarak işaretli, yalnızca
/// yıl/ay/gün taşır.
DateTime istanbulToday(DateTime now) {
  final t = now.toUtc().add(const Duration(hours: 3));
  return DateTime.utc(t.year, t.month, t.day);
}

/// "YYYY-MM-DD" -> takvim günü (UTC 00:00). Boş/geçersiz değerde null.
DateTime? parseApiDate(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// Takvim günü -> backend tarih biçimi "YYYY-MM-DD".
String apiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Vadeye kalan gün sayısı (negatif = gecikme). Vade yoksa null.
int? daysUntilDue(String? dueDate, DateTime today) {
  final due = parseApiDate(dueDate);
  if (due == null) return null;
  final t = DateTime.utc(today.year, today.month, today.day);
  return due.difference(t).inDays;
}

/// Açık (tahsil edilmemiş/ödenmemiş) bir kaydın vade ipucu: "12 gün
/// gecikti", "Bugün vadeli", "5 gün kaldı" (en çok [horizonDays] gün
/// ileriye kadar). Sayı ile birim bölünmez boşlukla bağlanır.
({String text, DueTone tone})? dueHint(String? dueDate, DateTime today, {int horizonDays = 14}) {
  final days = daysUntilDue(dueDate, today);
  if (days == null) return null;
  if (days < 0) return (text: '${-days}${kNbsp}gün gecikti', tone: DueTone.overdue);
  if (days == 0) return (text: 'Bugün vadeli', tone: DueTone.soon);
  if (days <= horizonDays) return (text: '$days${kNbsp}gün kaldı', tone: DueTone.soon);
  return null;
}

enum DueTone { overdue, soon }

/// Kullanıcının yazdığı tutarı çözer: "1250000", "1250000,50", "1.250.000,50",
/// "1,250,000.50" ve "12.5" kabul edilir. Hem nokta hem virgül varsa SONDAKİ
/// ondalık ayırıcıdır; tek tür ayırıcı birden çok kez geçiyorsa binlik
/// ayırıcıdır. Virgülsüz yazımda noktalar üçlü gruplar hâlindeyse ("64.000",
/// "1.250") Türkçe binlik ayırıcıdır -- bütçe (`parseTrDecimal`) ve personel
/// formlarıyla aynı kural; "64.000" ASLA 64 TL okunmaz. Geçersizse null.
double? parseAmountInput(String raw) {
  var s = raw.trim().replaceAll(' ', '').replaceAll(' ', '');
  if (s.isEmpty) return null;
  final lastDot = s.lastIndexOf('.');
  final lastComma = s.lastIndexOf(',');
  if (lastDot >= 0 && lastComma >= 0) {
    if (lastComma > lastDot) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (lastComma >= 0) {
    s = ','.allMatches(s).length > 1 ? s.replaceAll(',', '') : s.replaceAll(',', '.');
  } else if (lastDot >= 0 && ('.'.allMatches(s).length > 1 || RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s))) {
    s = s.replaceAll('.', '');
  }
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return null;
  return double.tryParse(s);
}

/// Ödeme planı "Yüzde (%)" alanı: nokta ve virgül İKİSİ de ondalık
/// ayırıcıdır, binlik gruplama YOKTUR -- tutar ayrıştırıcısı
/// ([parseAmountInput]) "33.333"ü 33 333 okur (binlik kuralı), yüzdeyi
/// yüzlerce kat büyütürdü. Sütun numeric(5,2): en çok 2 ondalık ("33,33").
/// Aralık (0 < p <= 100) çağıranın doğrulamasıdır. Geçersizse null.
double? parsePercentInput(String raw) {
  final s = raw.trim().replaceAll(' ', '').replaceAll('%', '');
  if (!RegExp(r'^\d{1,3}([.,]\d{1,2})?$').hasMatch(s)) return null;
  return double.tryParse(s.replaceAll(',', '.'));
}

import 'package:intl/intl.dart';

/// Firma Grubu'nun gün ve saat metinleri. Saatler İstanbul saatiyle (UTC+3,
/// yaz saati yok) -- sunucunun "bugün"üyle aynı gün; telefonun saat dilimi
/// başka olsa da şantiyedeki herkes aynı günü görür (bkz. Formatters.hm).

DateTime _istanbul(DateTime instant) => instant.toUtc().add(const Duration(hours: 3));

/// Mesajın İstanbul takvim günü (gün ayracı karşılaştırması için).
DateTime? chatDay(String rfc3339) {
  final t = DateTime.tryParse(rfc3339);
  if (t == null) return null;
  final i = _istanbul(t);
  return DateTime.utc(i.year, i.month, i.day);
}

DateTime chatDayOf(DateTime instant) {
  final i = _istanbul(instant);
  return DateTime.utc(i.year, i.month, i.day);
}

/// Gün ayracı: "Bugün", "Dün", bu yıl "12 Ekim Pazartesi", eski yıllar
/// "12 Ekim 2025". [now] cihaz saati (testte sabit, bkz. clock).
String chatDayLabel(DateTime day, DateTime now) {
  final today = chatDayOf(now);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Bugün';
  if (diff == 1) return 'Dün';
  if (day.year == today.year) return DateFormat('d MMMM EEEE', 'tr_TR').format(day);
  return DateFormat('d MMMM y', 'tr_TR').format(day);
}

/// Balondaki saat: "14:05" (İstanbul).
String chatTime(String rfc3339) {
  final t = DateTime.tryParse(rfc3339);
  if (t == null) return '';
  final i = _istanbul(t);
  return '${i.hour.toString().padLeft(2, '0')}:${i.minute.toString().padLeft(2, '0')}';
}

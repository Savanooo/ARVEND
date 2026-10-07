import 'package:intl/intl.dart';

/// Bölünmez boşluk (U+00A0): sayı ile birimi ("13 gün", "%8,4 aşım",
/// "dün 16:12") dar satırda ayrı satırlara düşmesin diye ana sayfa
/// metinlerinde kullanılır.
const kNbsp = '\u00a0';

/// Eksi işareti (U+2212): tablo rakamlı (tabularFigures) metinde ASCII
/// kısa çizgi rakam genişliğinde çizilip sayıdan kopuk görünür; eksi
/// işareti "+" ile aynı genişliktedir.
const kMinus = '\u2212';

/// Backend'den gelen sayılar (offers/projects: JSON number, calculations:
/// JSON string) burada YALNIZCA görüntülenmek için parse edilir - mobilde
/// hiçbir yerde bunlar üzerinden yeniden toplam/çarpım hesaplanmaz (bkz.
/// AGENTS talimatı "Backend business logic authoritative kalacak").
abstract final class Formatters {
  static final _moneyFormat = NumberFormat.decimalPattern('tr_TR')
    ..maximumFractionDigits = 2
    ..minimumFractionDigits = 2;
  static final _dateFormat = DateFormat('dd.MM.yyyy', 'tr_TR');
  static final _dateTimeFormat = DateFormat('dd.MM.yyyy HH:mm', 'tr_TR');

  static String money(num amount, {String currency = 'TRY'}) =>
      '${_moneyFormat.format(amount)} ${_currencySymbol(currency)}';

  /// Tam tutar, işaretli ("+950.000,00 TL" / "-310.000,00 TL"; sıfırda
  /// işaret yok) -- ana sayfadaki "Bu ay" dökümü için. Renge tek başına
  /// güvenilmez, işaret her zaman yazılır.
  static String signedMoney(num amount, {String currency = 'TRY'}) {
    if (amount > 0) return '+${money(amount, currency: currency)}';
    if (amount < 0) return '$kMinus${money(amount.abs(), currency: currency)}';
    return money(0, currency: currency);
  }

  static final _integerFormat = NumberFormat.decimalPattern('tr_TR')..maximumFractionDigits = 0;
  static final _oneDecimalFormat = NumberFormat.decimalPattern('tr_TR')
    ..minimumFractionDigits = 0
    ..maximumFractionDigits = 1;

  /// Ana sayfa kısa sayı kuralı (spec D5, web `formatCompactMoney` ile
  /// BİREBİR): 1.000.000 altı gruplanmış tam sayı ("850.000"), üstü tek
  /// ondalıklı "Mn" ("12,5 Mn"; sondaki ",0" atılır -> "12 Mn"),
  /// 1.000.000.000 ve üstü "Mr". "B"/"Bin" ASLA kullanılmaz. Yuvarlama
  /// yarımda sıfırdan uzağa (web'in `halfExpand`'i ile aynı) ve bir üst
  /// basamağa taşar (999.999,6 -> "1 Mn"). Grafik ekseni bunu para birimi
  /// eki OLMADAN kullanır.
  static String compactNumber(num value) {
    final abs = value.abs().toDouble();
    final String body;
    final whole = abs.roundToDouble();
    if (whole < 1e6) {
      body = _integerFormat.format(whole);
    } else {
      final millions = (abs / 1e6 * 10).round() / 10;
      if (millions < 1000) {
        body = '${_oneDecimalFormat.format(millions)} Mn';
      } else {
        body = '${_oneDecimalFormat.format((abs / 1e9 * 10).round() / 10)} Mr';
      }
    }
    // Yuvarlanınca sıfıra düşen küçük negatifler "-0" olmasın.
    return value < 0 && body != '0' ? '-$body' : body;
  }

  /// Kısa tutar + para birimi eki ("5,1 Mn TL", "45.000 $").
  static String moneyCompact(num amount, {String currency = 'TRY'}) =>
      '${compactNumber(amount)} ${_currencySymbol(currency)}';

  /// İşaretli kısa tutar ("+420.000 TL", "−70.000 TL"; sıfırda işaret
  /// yok). Eksi, U+2212'dir (bkz. [kMinus]).
  static String signedMoneyCompact(num amount, {String currency = 'TRY'}) {
    final text = moneyCompact(amount, currency: currency);
    if (amount > 0 && compactNumber(amount) != '0') return '+$text';
    if (text.startsWith('-')) return '$kMinus${text.substring(1)}';
    return text;
  }

  /// Gruplanmış, en çok 1 ondalıklı sayı ("4.120,5") -- saat gibi para
  /// olmayan değerler için.
  static String decimal(num value) => _oneDecimalFormat.format((value * 10).round() / 10);

  /// Dosya boyutu: "512 B", "20 KB", "1,5 MB" (1024 tabanlı, en çok 1
  /// ondalık). Eskiden hep KB yazılıyordu ("0 KB", "20480 KB").
  static String fileSize(int bytes) {
    if (bytes < 1024) return '${bytes < 0 ? 0 : bytes} B';
    final kb = (bytes / 1024 * 10).round() / 10;
    if (kb < 1024) return '${_oneDecimalFormat.format(kb)} KB';
    final mb = (bytes / (1024 * 1024) * 10).round() / 10;
    if (mb < 1024) return '${_oneDecimalFormat.format(mb)} MB';
    return '${_oneDecimalFormat.format((bytes / (1024 * 1024 * 1024) * 10).round() / 10)} GB';
  }

  /// Yüzde, en çok 1 ondalık ("%59", "%62,5"). Türkçe yazımda % başta.
  static String percent(num value) => '%${_oneDecimalFormat.format((value * 10).round() / 10)}';

  /// Türkiye 2016'dan beri sabit UTC+3'tür (yaz saati yok) -- ana sayfadaki
  /// saatler cihazın saat diliminden BAĞIMSIZ olarak İstanbul saatiyle
  /// gösterilir (spec D6/D20). Dönen DateTime'ın alanları İstanbul duvar
  /// saatidir (UTC olarak işaretli, yalnızca biçimlemek için).
  static DateTime _istanbul(DateTime instant) => instant.toUtc().add(const Duration(hours: 3));

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// RFC3339 zaman damgası -> İstanbul "HH:mm".
  static String hm(String? rfc3339) {
    final parsed = rfc3339 == null ? null : DateTime.tryParse(rfc3339);
    if (parsed == null) return '-';
    final t = _istanbul(parsed);
    return '${_two(t.hour)}:${_two(t.minute)}';
  }

  /// Göreli zaman -- "şimdi" cihaz saati DEĞİL, sunucunun `generated_at`
  /// değeridir (deterministik). az önce · 12 dk önce · 3 sa önce ·
  /// dün 17:40 · 27.09 14:05 · 27.09.2025.
  static String relative(String iso, String nowIso) {
    final t = DateTime.tryParse(iso);
    final now = DateTime.tryParse(nowIso);
    if (t == null || now == null) return iso;
    final diff = now.difference(t);
    if (diff.inSeconds < 60) return 'az önce';
    if (diff.inMinutes < 60) return '${diff.inMinutes}${kNbsp}dk önce';
    final ti = _istanbul(t);
    final ni = _istanbul(now);
    final dayDiff = DateTime.utc(ni.year, ni.month, ni.day).difference(DateTime.utc(ti.year, ti.month, ti.day)).inDays;
    final clock = '${_two(ti.hour)}:${_two(ti.minute)}';
    // Sayı ile birimi / gün ile saati bölünmez boşluk bağlar (dar satırda
    // "dün" bir satırda, "16:12" diğerinde kalmasın).
    if (dayDiff == 0) return '${diff.inHours}${kNbsp}sa önce';
    if (dayDiff == 1) return 'dün$kNbsp$clock';
    if (ti.year == ni.year) return '${_two(ti.day)}.${_two(ti.month)}$kNbsp$clock';
    return '${_two(ti.day)}.${_two(ti.month)}.${ti.year}';
  }

  /// "2026-09-28" -> "28 Eylül 2026, Pazartesi".
  static String longDate(String? isoDate) {
    final parsed = isoDate == null ? null : DateTime.tryParse(isoDate);
    if (parsed == null) return isoDate ?? '-';
    return DateFormat('d MMMM y, EEEE', 'tr_TR').format(parsed);
  }

  /// "2026-09-30" -> "30 Eyl".
  static String shortDayMonth(String? isoDate) {
    final parsed = isoDate == null ? null : DateTime.tryParse(isoDate);
    if (parsed == null) return isoDate ?? '-';
    return DateFormat('dd MMM', 'tr_TR').format(parsed);
  }

  /// /calculations/* uçlarının JSON-string sayıları için.
  static String moneyFromString(String value, {String currency = 'TRY'}) {
    final parsed = double.tryParse(value);
    if (parsed == null) return value;
    return money(parsed, currency: currency);
  }

  static String quantityFromString(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null) return value;
    // Miktarlar 6 hane hassasiyetle saklanır ama gösterimde gereksiz sıfırlar
    // kırpılır (ör. "100.000000" -> "100").
    final fixed = parsed.toStringAsFixed(6);
    return fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  static String _currencySymbol(String currency) => switch (currency) {
        'TRY' || '' => 'TL',
        'USD' => '\$',
        'EUR' => '€',
        _ => currency,
      };

  /// "YYYY-MM-DD" -> "dd.MM.yyyy". Parse edilemeyen değeri olduğu gibi döner.
  /// RFC3339 zaman damgası da kabul edilir (ör. dosya/fotoğraf yükleme
  /// anı): `dateTime` gibi yerel saate çevrilir -- aksi halde İstanbul'da
  /// 00:00-03:00 arası yüklenen dosya bir önceki günün tarihiyle görünürdü.
  /// Saatsiz tarih ("2026-09-01") zaten yerel gün olarak okunur, kaymaz.
  static String date(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return '-';
    try {
      final parsed = DateTime.parse(isoDate);
      return _dateFormat.format(parsed.isUtc ? parsed.toLocal() : parsed);
    } on FormatException {
      return isoDate;
    }
  }

  /// RFC3339 zaman damgası -> "dd.MM.yyyy HH:mm" (yerel saat dilimine çevrilir).
  static String dateTime(String? rfc3339) {
    if (rfc3339 == null || rfc3339.isEmpty) return '-';
    try {
      return _dateTimeFormat.format(DateTime.parse(rfc3339).toLocal());
    } on FormatException {
      return rfc3339;
    }
  }
}

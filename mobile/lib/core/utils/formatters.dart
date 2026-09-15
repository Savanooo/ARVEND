import 'package:intl/intl.dart';

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
  static String date(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return '-';
    try {
      return _dateFormat.format(DateTime.parse(isoDate));
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

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:arvend/core/utils/formatters.dart';

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  test('zaman damgası yerel güne çevrilir (İstanbul 00:00-03:00 arası önceki gün görünmez)', () {
    // 06.10 22:30 UTC = 07.10 01:30 İstanbul.
    const stamp = '2026-10-06T22:30:00Z';
    final local = DateTime.utc(2026, 10, 6, 22, 30).toLocal();
    final expected = DateFormat('dd.MM.yyyy', 'tr_TR').format(local);
    expect(Formatters.date(stamp), expected);
    if (local.timeZoneOffset == const Duration(hours: 3)) {
      expect(Formatters.date(stamp), '07.10.2026');
    }
    // Ofsetli damga da aynı an.
    expect(Formatters.date('2026-10-07T01:30:00+03:00'), expected);
  });

  test('saatsiz tarih kaymaz; boş/bozuk değer korunur', () {
    expect(Formatters.date('2026-09-01'), '01.09.2026');
    expect(Formatters.date(null), '-');
    expect(Formatters.date(''), '-');
    expect(Formatters.date('yarın'), 'yarın');
  });
}

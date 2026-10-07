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

  test('dosya boyutu B/KB/MB', () {
    expect(Formatters.fileSize(0), '0 B');
    expect(Formatters.fileSize(512), '512 B');
    expect(Formatters.fileSize(1024), '1 KB');
    expect(Formatters.fileSize(1536), '1,5 KB');
    expect(Formatters.fileSize(20480), '20 KB');
    expect(Formatters.fileSize(20971520), '20 MB');
    expect(Formatters.fileSize(1048575), '1 MB', reason: '1023,99 KB "1.024 KB" yazılmaz');
    expect(Formatters.fileSize(26214400), '25 MB');
  });

  test('saatsiz tarih kaymaz; boş/bozuk değer korunur', () {
    expect(Formatters.date('2026-09-01'), '01.09.2026');
    expect(Formatters.date(null), '-');
    expect(Formatters.date(''), '-');
    expect(Formatters.date('yarın'), 'yarın');
  });
}

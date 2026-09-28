import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/update/update_postpone_store.dart';

void main() {
  late DateTime now;
  late UpdatePostponeStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 9, 28, 10);
    store = UpdatePostponeStore(clock: () => now);
  });

  test('hiç ertelenmemiş build ertelenmiş sayılmaz', () async {
    expect(await store.isPostponed(3), isFalse);
  });

  test('"Sonra" o build\'i 24 saat erteler', () async {
    await store.postpone(3);
    expect(await store.isPostponed(3), isTrue);

    now = now.add(const Duration(hours: 23, minutes: 59));
    expect(await store.isPostponed(3), isTrue);

    now = now.add(const Duration(minutes: 1));
    expect(await store.isPostponed(3), isFalse, reason: '24 saat doldu');
  });

  test('erteleme build\'e bağlı: daha yeni bir build hemen sorulur', () async {
    await store.postpone(3);
    expect(await store.isPostponed(4), isFalse);
    expect(await store.isPostponed(2), isFalse);
  });

  test('yeni bir erteleme öncekinin yerine geçer', () async {
    await store.postpone(3);
    now = now.add(const Duration(hours: 2));
    await store.postpone(4);
    expect(await store.isPostponed(3), isFalse);
    expect(await store.isPostponed(4), isTrue);
  });

  test('cihaz saati geri alınırsa erteleme sonsuza uzamaz', () async {
    await store.postpone(3);
    now = now.subtract(const Duration(days: 30));
    expect(await store.isPostponed(3), isFalse);
  });

  test('tercih kalıcıdır (SharedPreferences\'a yazılır)', () async {
    await store.postpone(7);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UpdatePostponeStore.buildKey), 7);
    expect(prefs.getInt(UpdatePostponeStore.atKey), now.millisecondsSinceEpoch);

    // Yeni bir örnek (uygulama yeniden açıldı) aynı kararı okur.
    expect(await UpdatePostponeStore(clock: () => now).isPostponed(7), isTrue);
  });

  test('tercihler okunamazsa ertelenmemiş sayılır (en kötü ihtimalle tekrar sorulur)', () async {
    final broken = UpdatePostponeStore(prefs: () => Future.error(StateError('yok')), clock: () => now);
    await broken.postpone(3);
    expect(await broken.isPostponed(3), isFalse);
  });
}

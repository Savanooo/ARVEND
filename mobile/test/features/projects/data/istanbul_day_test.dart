import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/projects/data/istanbul_day.dart';
import 'package:arvend/features/projects/ops_team/domain/ops_dates.dart' show istanbulToday;

/// "Bugün" sağlayıcıları gün değişince kendini yeniler: önplanda İstanbul gece
/// yarısında (zamanlayıcı), arka plandan dönüşte (yaşam döngüsü). Regresyon:
/// değer eskiden uygulama süreci boyunca ilk günde donuyordu.
void main() {
  late DateTime fakeNow;
  final todayProvider = Provider.autoDispose<DateTime>(
    (ref) => trackIstanbulDay(ref, istanbulToday, clock: () => fakeNow),
  );

  Widget app() => ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final d = ref.watch(todayProvider);
              return Text('${d.year}-${d.month}-${d.day}', textDirection: TextDirection.ltr);
            },
          ),
        ),
      );

  testWidgets('önplanda İstanbul gece yarısı geçince yeni güne geçer', (tester) async {
    // 28.09 23:30 İstanbul = 20:30Z.
    fakeNow = DateTime.utc(2026, 9, 28, 20, 30);
    await tester.pumpWidget(app());
    expect(find.text('2026-9-28'), findsOneWidget);

    fakeNow = DateTime.utc(2026, 9, 28, 21, 0, 2); // 29.09 00:00:02 İstanbul
    await tester.pump(const Duration(minutes: 31));
    await tester.pump();
    expect(find.text('2026-9-29'), findsOneWidget);
  });

  testWidgets('arka plandan dönüşte gün değiştiyse yenilenir, değişmediyse aynı kalır', (tester) async {
    fakeNow = DateTime.utc(2026, 9, 29, 7, 0); // Pazartesi 10:00 İstanbul
    await tester.pumpWidget(app());
    expect(find.text('2026-9-29'), findsOneWidget);

    Future<void> backgroundAndResume() async {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
    }

    // Aynı gün içinde dönüş: değişmez.
    fakeNow = DateTime.utc(2026, 9, 29, 9, 0);
    await backgroundAndResume();
    expect(find.text('2026-9-29'), findsOneWidget);

    // Perşembe dönüş (cihaz uyurken zamanlayıcı ilerlememiş olabilir).
    fakeNow = DateTime.utc(2026, 10, 2, 6, 0);
    await backgroundAndResume();
    expect(find.text('2026-10-2'), findsOneWidget);
  });
}

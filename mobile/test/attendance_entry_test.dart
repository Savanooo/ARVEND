import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/attendance/domain/attendance_entry.dart';
import 'package:arvend/features/attendance/presentation/attendance_screen.dart';

import 'test_utils/fake_api_client.dart';

/// Mesai girişi: saf yardımcılar + toplu giriş (sahadan, 2026-10: "adamı
/// seçecek, ayın 1'inden 5'ine").
void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('yardımcılar', () {
    test('entryDays: iki uç dahil, pazar varsayılan atlanır, ay geçişi doğru', () {
      // 2026-10-01 Perşembe ... 2026-10-05 Pazartesi; 4 Ekim Pazar.
      final days = entryDays(DateTime(2026, 10, 1), DateTime(2026, 10, 5));
      expect(days.map(isoDate), ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-05']);
      expect(entryDays(DateTime(2026, 10, 1), DateTime(2026, 10, 5), skipSundays: false), hasLength(5));
      expect(entryDays(DateTime(2026, 9, 29), DateTime(2026, 10, 2), skipSundays: false).map(isoDate),
          ['2026-09-29', '2026-09-30', '2026-10-01', '2026-10-02']);
      expect(entryDays(DateTime(2026, 10, 5), DateTime(2026, 10, 1)), isEmpty, reason: 'ters aralık');
    });

    test('hoursBetween: düz fark (BYZ ile aynı), geçersizde null', () {
      expect(hoursBetween('08:00', '17:00'), 9);
      expect(hoursBetween('08:30', '12:00'), 3.5);
      expect(hoursBetween('17:00', '08:00'), isNull);
      expect(hoursBetween('8', '17:00'), isNull);
      expect(hoursBetween('25:00', '26:00'), isNull);
    });

    test('gelmedi/izinli günde saat yok', () {
      expect(statusHasHours('geldi'), isTrue);
      expect(statusHasHours('yarım gün'), isTrue);
      expect(statusHasHours('gelmedi'), isFalse);
      expect(statusHasHours('izinli'), isFalse);
    });

    test('BulkEntryResult özeti', () {
      expect(const BulkEntryResult(created: 8, skipped: 2).summary, '8 kayıt eklendi · 2 gün zaten kayıtlıydı, atlandı');
      expect(const BulkEntryResult(created: 3, skipped: 0, error: 'yetki yok').summary, '3 kayıt eklendi · durdu: yetki yok');
    });
  });

  group('toplu giriş', () {
    Future<FakeHttpClientAdapter> pumpBulk(WidgetTester tester, List<ScriptedResponse> creates) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/employees': [
          (
            status: 200,
            body: {
              'employees': [
                {'id': 'e1', 'full_name': 'Ali Kaya', 'position': 'Usta', 'is_active': true},
                {'id': 'e2', 'full_name': 'Veli Er', 'position': 'Kalfa', 'is_active': true},
              ],
            },
          ),
        ],
        '/attendance': creates,
      });
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showAttendanceForm(
                      context,
                      onSaved: () {},
                      // 2026-10-05 Pazartesi -> aralık 1-5 Ekim.
                      initialDate: DateTime(2026, 10, 5),
                    ),
                    child: const Text('aç'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toplu'));
      await tester.pumpAndSettle();
      return adapter;
    }

    Map<String, dynamic> created(String emp, String date) => {
          'id': 'x-$emp-$date', 'employee_id': emp, 'employee_name': '', 'date': date,
          'check_in': '08:00', 'check_out': '17:00', 'work_hours': 9, 'status': 'geldi', 'note': '',
        };

    testWidgets('iki kişi × ayın 1-5 (pazar hariç 4 gün) = 8 kayıt; mevcut gün (409) atlanır', (tester) async {
      final adapter = await pumpBulk(tester, [
        for (final emp in ['e1', 'e2'])
          for (final d in ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-05'])
            emp == 'e2' && d == '2026-10-02'
                ? (status: 409, body: {'error': 'bu personel için bu tarihte zaten mesai kaydı var'})
                : (status: 201, body: created(emp, d)),
      ]);

      expect(find.text('Kişi ve tarih aralığı seç.'), findsOneWidget);
      await tester.tap(find.text('Tümü (2)'));
      await tester.pumpAndSettle();
      expect(find.text('2 kişi × 4 gün = 8 kayıt girilecek.'), findsOneWidget);

      await tester.ensureVisible(find.text('8 kaydı gir'));
      await tester.tap(find.text('8 kaydı gir'));
      await tester.pumpAndSettle();

      final posts = [
        for (var i = 0; i < adapter.calls.length; i++)
          if (adapter.calls[i] == '/attendance' && adapter.requestBodies[i] is Map) adapter.requestBodies[i] as Map,
      ];
      expect(posts, hasLength(8));
      expect(posts.map((b) => b['date']).toSet(), {'2026-10-01', '2026-10-02', '2026-10-03', '2026-10-05'});
      expect(posts.every((b) => b['work_hours'] == 9 && b['status'] == 'geldi'), isTrue);
      expect(find.text('7 kayıt eklendi · 1 gün zaten kayıtlıydı, atlandı'), findsOneWidget, reason: 'sonuç bildirimi');
    });

    testWidgets('gelmedi seçilirse saat alanları gizlenir, 0 saat ve boş giriş-çıkış gider', (tester) async {
      final adapter = await pumpBulk(tester, [
        for (final d in ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-05'])
          (status: 201, body: created('e1', d)),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'Ali Kaya'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Gelmedi'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mesai-saat')), findsNothing);

      await tester.ensureVisible(find.text('4 kaydı gir'));
      await tester.tap(find.text('4 kaydı gir'));
      await tester.pumpAndSettle();
      final body = adapter.requestBodies[adapter.calls.indexOf('/attendance')] as Map;
      expect(body['status'], 'gelmedi');
      expect(body['work_hours'], 0);
      expect(body['check_in'], '');
    });
  });
}

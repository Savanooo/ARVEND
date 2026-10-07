import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/attendance/domain/attendance.dart';
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

    test('parseWorkHours: Türkçe virgül kabul, "8 saat" gibi metin geçersiz', () {
      expect(parseWorkHours('8'), 8);
      expect(parseWorkHours('7,5'), 7.5);
      expect(parseWorkHours(' 7.25 '), 7.25);
      expect(parseWorkHours('0'), 0);
      expect(parseWorkHours('24'), 24);
      expect(parseWorkHours('8 saat'), isNull);
      expect(parseWorkHours(''), isNull);
      expect(parseWorkHours('-1'), isNull);
      expect(parseWorkHours('25'), isNull);
      expect(parseWorkHours('1.000'), isNull, reason: 'binlik ayraç saat değildir');
    });

    test('mesai günü bugünü (İstanbul) geçemez', () {
      // UTC 22:30 = İstanbul ertesi gün 01:30.
      final now = DateTime.utc(2026, 10, 7, 22, 30);
      expect(attendanceLastDay(now), DateTime(2026, 10, 8));
      expect(clampToAttendanceDay(DateTime(2026, 11, 1), now), DateTime(2026, 10, 8));
      expect(clampToAttendanceDay(DateTime(2026, 10, 3, 15), now), DateTime(2026, 10, 3));
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

    testWidgets('geçersiz saat ("8 saat") kaydedilmez, hata gösterilir', (tester) async {
      final adapter = await pumpBulk(tester, [
        for (final d in ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-05'])
          (status: 201, body: created('e1', d)),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'Ali Kaya'));
      await tester.enterText(find.byKey(const Key('mesai-saat')), '8 saat');
      await tester.ensureVisible(find.text('4 kaydı gir'));
      await tester.tap(find.text('4 kaydı gir'));
      await tester.pumpAndSettle();
      expect(adapter.calls.where((c) => c == '/attendance'), isEmpty, reason: 'istek gitmemeli');
      expect(find.textContaining('Çalışma saati geçersiz'), findsOneWidget);
    });
  });

  testWidgets('gelmedi kaydı geldi yapılınca saat giriş-çıkıştan hesaplanır (0 kalmaz)', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/attendance/a1': [
        (
          status: 200,
          body: {
            'id': 'a1', 'employee_id': 'e1', 'employee_name': 'Ali Kaya', 'date': '2026-10-02',
            'check_in': '08:00', 'check_out': '17:00', 'work_hours': 9, 'status': 'geldi', 'note': '',
          },
        ),
      ],
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
                    existing: const AttendanceRecord(
                      id: 'a1', employeeId: 'e1', employeeName: 'Ali Kaya', date: '2026-10-02',
                      checkIn: '', checkOut: '', workHours: 0, status: 'gelmedi', note: '',
                    ),
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
    await tester.tap(find.widgetWithText(ChoiceChip, 'Geldi'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '9'), findsOneWidget);
    await tester.ensureVisible(find.text('Kaydet'));
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();
    final body = adapter.requestBodies[adapter.calls.indexOf('/attendance/a1')] as Map;
    expect(body['status'], 'geldi');
    expect(body['work_hours'], 9);
    expect(body['check_in'], '08:00');
  });
}

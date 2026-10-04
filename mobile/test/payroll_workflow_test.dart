import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/attendance/presentation/attendance_screen.dart';
import 'package:arvend/features/payroll/data/payroll_repository.dart';
import 'package:arvend/features/payroll/domain/payroll.dart';

import 'test_utils/fake_api_client.dart';

/// Maaş ve mesai ödemeleri (backend migration 0048, GET/POST/DELETE /payroll).
///
/// En kritik davranış görünürlük: maaş tutarı hassas olduğu için Mesai
/// ekranının "izin listesi boşsa her şey görünür" kuralı burada GEÇERLİ
/// DEĞİL -- payroll.read yoksa sekme yok VE /payroll hiç çağrılmaz.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('parsing', () {
    test('PayrollMonth.fromJson reads summary + payments exactly as the backend sends them', () {
      final m = PayrollMonth.fromJson(_payrollJson());
      expect(m.period, '2026-09');
      expect(m.summary, hasLength(3));
      final ahmet = m.summary.first;
      expect(ahmet.fullName, 'Ahmet Usta');
      expect(ahmet.salary, isNull, reason: 'maaşı tanımsız personel null gelir, 0 değil');
      expect(ahmet.dailyWage, 1500);
      expect(ahmet.workedDays, 21.5);
      expect(ahmet.paidTotal, 30000.5);
      expect(ahmet.paymentCount, 2);
      // Hesap backend'den gelir, burada yeniden yapılmaz.
      expect(ahmet.wageBasis, 'günlük');
      expect(ahmet.earned, 32250);
      expect(ahmet.remaining, 2249.5);
      expect(ahmet.isWaiting, isTrue);
      final kalfa = m.summary[1];
      expect(kalfa.extraPaid, 1000);
      expect(kalfa.isSettled, isTrue);
      expect(m.summary[2].hasWage, isFalse);
      expect(m.payments, hasLength(2));
      expect(m.payments.first.paymentType, 'avans');
      expect(m.payments.first.paidDate, '2026-09-15');
    });

    test('toPay sums only rows still owed; payableEmployees keeps the inactive one', () {
      final m = PayrollMonth.fromJson(_payrollJson());
      expect(m.paidTotal, 30000.5 + 21000);
      expect(m.toPay, 2249.5, reason: 'ödenmiş ve ücreti tanımsız satır toplama girmez');
      expect(m.waitingCount, 1);
      // İşten ayrılanın son maaşı da ödenebilmeli.
      expect(m.payableEmployees.map((e) => e.employeeId), ['e1', 'e2', 'e3']);
    });

    test('older server without the calculation fields: nothing is claimed as owed', () {
      final row = PayrollSummaryRow.fromJson({'employee_id': 'e1', 'full_name': 'Eski Sunucu'});
      expect(row.hasWage, isFalse);
      expect(row.isWaiting, isFalse);
    });

    test('isValidPeriod matches the backend CHECK', () {
      for (final ok in ['2026-01', '2026-09', '2026-12']) {
        expect(isValidPeriod(ok), isTrue, reason: ok);
      }
      for (final bad in ['2026-13', '2026-9', '2026/09', '26-09', '']) {
        expect(isValidPeriod(bad), isFalse, reason: bad);
      }
    });
  });

  group('repository', () {
    test('month() GETs /payroll with the month query', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/payroll': [(status: 200, body: _payrollJson())],
      });
      final repo = PayrollRepository(await buildFakeApiClient(adapter));
      await repo.month('2026-09');
      expect(adapter.calls.single, '/payroll');
      expect(adapter.requestQueries.single['month'], '2026-09');
    });

    test('create() POSTs exactly the backend contract fields', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/payroll': [(status: 201, body: _paymentJson(id: 'p9'))],
      });
      final repo = PayrollRepository(await buildFakeApiClient(adapter));
      final p = await repo.create(
        employeeId: 'e1',
        period: '2026-09',
        paymentType: 'avans',
        amount: 1250.5,
        paidDate: '2026-09-15',
        description: 'Ekim avansı',
      );
      expect(p.id, 'p9');
      expect(adapter.requestBodies.single, {
        'employee_id': 'e1',
        'period': '2026-09',
        'payment_type': 'avans',
        'amount': 1250.5,
        'paid_date': '2026-09-15',
        'description': 'Ekim avansı',
      });
    });

    test('delete() hits /payroll/{id}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/payroll/p1': [(status: 200, body: {'ok': true})],
      });
      final repo = PayrollRepository(await buildFakeApiClient(adapter));
      await repo.delete('p1');
      expect(adapter.calls.single, '/payroll/p1');
    });
  });

  group('visibility on the Mesai screen', () {
    testWidgets('without payroll.read: no Maaş tab and /payroll is NEVER called', (tester) async {
      final adapter = _adapter(permissions: ['attendance.read', 'attendance.manage', 'employees.read']);
      await _pump(tester, adapter);

      expect(find.text('Maaş'), findsNothing);
      expect(find.text('Mesai'), findsOneWidget, reason: 'başlık eskisi gibi kalmalı');
      expect(adapter.calls, isNot(contains('/payroll')));
    });

    testWidgets('empty permission set (legacy session) does NOT reveal salaries', (tester) async {
      // Mesai bu durumda fail-open davranır; maaş davranMAMALI.
      final adapter = _adapter(permissions: const []);
      await _pump(tester, adapter);

      expect(find.text('Maaş'), findsNothing);
      expect(adapter.calls, isNot(contains('/payroll')));
    });

    testWidgets('payroll.read: tab shows the month, but no "Ödeme Ekle" without manage', (tester) async {
      final adapter = _adapter(permissions: ['attendance.read', 'payroll.read'], withPayroll: true);
      await _pump(tester, adapter);

      expect(find.text('Mesai & Maaş'), findsOneWidget);
      await tester.tap(find.text('Maaş'));
      await tester.pumpAndSettle();

      expect(adapter.calls, contains('/payroll'));
      expect(find.text('Ahmet Usta'), findsWidgets);
      expect(find.text('Ödeme Ekle'), findsNothing);
      expect(find.text('Öde'), findsNothing, reason: 'manage yoksa kartta Öde yok');
      expect(find.text('Bekliyor'), findsOneWidget);
      expect(find.text('Ödendi'), findsOneWidget);
      expect(find.text('Ücret tanımsız'), findsOneWidget);
      // Sekme değişince Puantaj'ın "+" düğmesi kaybolmalı (zaten manage yok).
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('payroll.manage: "Ödeme Ekle" is offered and the Puantaj FAB hides on the Maaş tab',
        (tester) async {
      final adapter = _adapter(
        permissions: ['attendance.read', 'attendance.manage', 'employees.read', 'payroll.read', 'payroll.manage'],
        withPayroll: true,
      );
      await _pump(tester, adapter);

      expect(find.byType(FloatingActionButton), findsOneWidget, reason: 'Puantaj sekmesinde FAB var');
      await tester.tap(find.text('Maaş'));
      await tester.pumpAndSettle();

      expect(find.text('Ödeme Ekle'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing, reason: 'Maaş sekmesinde Puantaj FAB\'ı karışıklık yaratır');
    });

    testWidgets('"Öde" opens the form with the employee selected and the remaining amount filled in',
        (tester) async {
      final adapter = _adapter(
        permissions: ['attendance.read', 'payroll.read', 'payroll.manage'],
        withPayroll: true,
      );
      await _pump(tester, adapter);
      await tester.tap(find.text('Maaş'));
      await tester.pumpAndSettle();

      expect(find.text('Öde'), findsOneWidget, reason: 'yalnızca kalanı olan satırda');
      await tester.tap(find.text('Öde'));
      await tester.pumpAndSettle();

      final amount = tester.widget<TextField>(find.byKey(const Key('payment-amount')));
      expect(amount.controller!.text, '2249,5');
      expect(find.textContaining('Kalan:'), findsOneWidget);
      expect(find.text('Ahmet Usta'), findsWidgets);
    });
  });

  group('avans (sahada "avans verme yok" -- 2026-10)', () {
    Map<String, dynamic> monthStart() => {
          'period': '2026-09',
          'summary': [
            {
              'employee_id': 'e1',
              'full_name': 'Ahmet Usta',
              'position': 'Usta',
              'salary': null,
              'daily_wage': 1500,
              'is_active': true,
              'worked_days': 0,
              'work_hours': 0,
              'paid_total': 0,
              'payment_count': 0,
              'wage_basis': 'günlük',
              'earned': 0,
              'salary_paid': 0,
              'extra_paid': 0,
              'carry_over': 0,
              'remaining': 0,
            },
          ],
          'payments': <dynamic>[],
        };

    FakeHttpClientAdapter adapter() => FakeHttpClientAdapter(script: {
          '/auth/me': [(status: 200, body: _meJson(['attendance.read', 'payroll.read', 'payroll.manage']))],
          '/attendance': [
            (status: 200, body: {'attendance': <Map<String, dynamic>>[]}),
          ],
          '/payroll': [
            (status: 200, body: monthStart()),
            (status: 201, body: _paymentJson(id: 'p9', type: 'avans', amount: 5000)),
            (status: 200, body: monthStart()),
          ],
        });

    testWidgets('ay başında (hakediş 0) kart "Çalışma yok" der, "Ödendi" DEĞİL; yine de Avans verilebilir',
        (tester) async {
      final a = adapter();
      await _pump(tester, a);
      await tester.tap(find.text('Maaş'));
      await tester.pumpAndSettle();

      expect(find.text('Çalışma yok'), findsOneWidget);
      expect(find.text('Ödendi'), findsNothing);
      expect(find.text('Öde'), findsNothing, reason: 'kalan yok');
      expect(find.text('Avans'), findsOneWidget, reason: 'avans kalandan bağımsız');

      await tester.tap(find.text('Avans'));
      await tester.pumpAndSettle();
      expect(find.text('Avans Ver'), findsWidgets, reason: 'form başlığı');
      final amount = tester.widget<TextField>(find.byKey(const Key('payment-amount')));
      expect(amount.controller!.text, isEmpty, reason: 'avansta kalan önerilmez');

      await tester.enterText(find.byKey(const Key('payment-amount')), '5.000');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      final body = a.requestBodies[a.calls.lastIndexOf('/payroll') - 1] as Map;
      expect(body['payment_type'], 'avans');
      expect(body['employee_id'], 'e1');
      expect(body['amount'], 5000);
    });

    testWidgets('üstteki "Avans Ver" formu avans türüyle açar', (tester) async {
      await _pump(tester, adapter());
      await tester.tap(find.text('Maaş'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Avans Ver'));
      await tester.pumpAndSettle();
      expect(find.text('Avans'), findsWidgets, reason: 'Tür kutusunda Avans seçili');
      expect(find.textContaining('Avans bu ayın maaşından düşülür'), findsOneWidget);
    });
  });

  group('attendance delete (web "Sil" parity)', () {
    testWidgets('editing a record offers "Kaydı Sil"; DELETE only after confirmation, list refreshes', (tester) async {
      final record = {
        'id': 'a1',
        'employee_id': 'e1',
        'employee_name': 'Ahmet Usta',
        'date': '2026-09-15',
        'check_in': '08:00',
        'check_out': '17:00',
        'work_hours': 9,
        'status': 'geldi',
        'note': '',
      };
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(['attendance.read', 'attendance.manage', 'employees.read']))],
        '/attendance': [
          (status: 200, body: {'attendance': [record]}),
          (status: 200, body: {'attendance': <Map<String, dynamic>>[]}),
        ],
        '/employees': [
          (
            status: 200,
            body: {
              'employees': [
                {'id': 'e1', 'full_name': 'Ahmet Usta', 'position': 'Usta', 'is_active': true},
              ],
            },
          ),
        ],
        '/attendance/a1': [(status: 200, body: {'ok': true})],
      });
      await _pump(tester, adapter);

      await tester.tap(find.textContaining('2026-09-15').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Kaydı Sil'));
      await tester.tap(find.text('Kaydı Sil'));
      await tester.pumpAndSettle();
      expect(find.text('Mesai kaydı silinsin mi?'), findsOneWidget);
      expect(adapter.calls, isNot(contains('/attendance/a1')));

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Sil')));
      await tester.pumpAndSettle();

      expect(adapter.calls, contains('/attendance/a1'));
      expect(adapter.calls.where((c) => c == '/attendance').length, 2, reason: 'silince liste tazelenir');
    });
  });
}

FakeHttpClientAdapter _adapter({required List<String> permissions, bool withPayroll = false}) {
  return FakeHttpClientAdapter(script: {
    '/auth/me': [(status: 200, body: _meJson(permissions))],
    '/attendance': [
      (status: 200, body: {'attendance': <Map<String, dynamic>>[]}),
    ],
    '/employees': [
      (
        status: 200,
        body: {
          'employees': [
            {'id': 'e1', 'full_name': 'Ahmet Usta', 'position': 'Usta', 'is_active': true},
          ],
        },
      ),
    ],
    if (withPayroll) '/payroll': [(status: 200, body: _payrollJson())],
  });
}

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      // Uygulamanın GERÇEK teması: birincil düğmeyi tam genişlik yapan
      // minimumSize'ı içerir. Temasız çalışınca Maaş sekmesindeki "Ödeme
      // Ekle" bir Row içinde sonsuz genişlik isterken test bunu görmüyordu.
      child: MaterialApp(theme: AppTheme.light(), home: const AttendanceScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _meJson(List<String> permissions) => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Ayşe Yılmaz',
      'organization_name': 'ARVEND Yapı A.Ş.',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    };

Map<String, dynamic> _paymentJson({required String id, String type = 'maaş', num amount = 25000.5}) => {
      'id': id,
      'employee_id': 'e1',
      'employee_name': 'Ahmet Usta',
      'period': '2026-09',
      'payment_type': type,
      'amount': amount,
      'paid_date': '2026-10-05',
      'description': '',
    };

Map<String, dynamic> _payrollJson() => {
      'period': '2026-09',
      'summary': [
        {
          'employee_id': 'e1',
          'full_name': 'Ahmet Usta',
          'position': 'Usta',
          'salary': null,
          'daily_wage': 1500,
          'is_active': true,
          'worked_days': 21.5,
          'work_hours': 13,
          'paid_total': 30000.5,
          'payment_count': 2,
          'wage_basis': 'günlük',
          'earned': 32250,
          'salary_paid': 30000.5,
          'extra_paid': 0,
          'carry_over': 0,
          'remaining': 2249.5,
        },
        {
          'employee_id': 'e2',
          'full_name': 'Ayrılan Kalfa',
          'position': '',
          'salary': 20000,
          'daily_wage': null,
          'is_active': false,
          'worked_days': 0,
          'work_hours': 0,
          'paid_total': 21000,
          'payment_count': 2,
          'wage_basis': 'aylık',
          'earned': 20000,
          'salary_paid': 20000,
          'extra_paid': 1000,
          'carry_over': 0,
          'remaining': 0,
        },
        {
          'employee_id': 'e3',
          'full_name': 'Yeni Çırak',
          'position': '',
          'salary': null,
          'daily_wage': null,
          'is_active': true,
          'worked_days': 3,
          'work_hours': 27,
          'paid_total': 0,
          'payment_count': 0,
          'wage_basis': '',
          'earned': 0,
          'salary_paid': 0,
          'extra_paid': 0,
          'carry_over': 0,
          'remaining': 0,
        },
      ],
      'payments': [
        {..._paymentJson(id: 'p1', type: 'avans', amount: 5000), 'paid_date': '2026-09-15'},
        _paymentJson(id: 'p2'),
      ],
    };

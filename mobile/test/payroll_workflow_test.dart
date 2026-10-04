import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
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
      expect(m.summary, hasLength(2));
      final ahmet = m.summary.first;
      expect(ahmet.fullName, 'Ahmet Usta');
      expect(ahmet.salary, isNull, reason: 'maaşı tanımsız personel null gelir, 0 değil');
      expect(ahmet.dailyWage, 1500);
      expect(ahmet.workedDays, 1.5);
      expect(ahmet.paidTotal, 30000.5);
      expect(ahmet.paymentCount, 2);
      expect(m.payments, hasLength(2));
      expect(m.payments.first.paymentType, 'avans');
      expect(m.payments.first.paidDate, '2026-09-15');
    });

    test('paidTotal sums the summary; payableEmployees excludes inactive', () {
      final m = PayrollMonth.fromJson(_payrollJson());
      expect(m.paidTotal, 30000.5 + 1000);
      expect(m.payableEmployees.map((e) => e.employeeId), ['e1']);
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
      child: const MaterialApp(home: AttendanceScreen()),
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
          'worked_days': 1.5,
          'work_hours': 13,
          'paid_total': 30000.5,
          'payment_count': 2,
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
          'paid_total': 1000,
          'payment_count': 1,
        },
      ],
      'payments': [
        {..._paymentJson(id: 'p1', type: 'avans', amount: 5000), 'paid_date': '2026-09-15'},
        _paymentJson(id: 'p2'),
      ],
    };

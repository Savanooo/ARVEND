import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/domain/subcontract.dart';
import 'package:arvend/features/projects/presentation/progress_claim_detail_screen.dart';
import 'package:arvend/features/projects/presentation/subcontract_payment_form_sheet.dart';

import '../../test_utils/fake_api_client.dart';

/// Hakedişin "Ödenmemiş Kalan"ı bu hakedişin NET tutarından düşülür
/// (kümülatif BRÜT sertifikadan değil) ve ödeme formu ödemeyi sertifikalı
/// bir hakedişe bağlayabilir (`progress_claim_id`).

class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

final _user = User(
  id: 'u1',
  organizationId: 'org1',
  username: 'finans',
  fullName: 'Finans Kullanıcı',
  role: UserRole.kullanici,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationName: 'Deneme Yapı',
  permissions: const {
    'projects.subcontract_claims.read',
    'projects.subcontract_payments.read',
    'projects.subcontract_payments.manage',
  },
);

Map<String, dynamic> _claim(String id, String number, {required String status, required double net, double cumulative = 0}) => {
      'id': id,
      'subcontract_id': 'sc1',
      'claim_number': number,
      'period_end': '2026-09-30',
      'status': status,
      'gross_work_amount': 100000,
      'retention_percent_snapshot': 5,
      'retention_amount': 5000,
      'other_deductions': 10000,
      'previous_certified_amount': cumulative - 100000,
      'current_certified_amount': cumulative,
      'net_payable': net,
    };

Map<String, dynamic> _payment(String id, double amount, {String? claimId, bool voided = false}) => {
      'id': id,
      'progress_claim_id': claimId,
      'amount': amount,
      'currency': 'TRY',
      'paid_date': '2026-10-01',
      'voided_at': voided ? '2026-10-02T08:00:00Z' : null,
      'created_at': '2026-10-01T08:00:00Z',
    };

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Widget home) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => _FakeAuth(_user)),
      ],
      child: MaterialApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  test('claimUnpaidRemainder: net hakediş − bu hakedişe karşı (iptal edilmemiş) ödenenler', () {
    final claim = ProgressClaim.fromJson(_claim('c2', 'HK-002', status: 'certified', net: 85000, cumulative: 300000));
    final payments = [
      SubcontractPayment.fromJson(_payment('p1', 50000, claimId: 'c2')),
      SubcontractPayment.fromJson(_payment('p2', 99999, claimId: 'c1')),
      SubcontractPayment.fromJson(_payment('p3', 10000, claimId: 'c2', voided: true)),
      SubcontractPayment.fromJson(_payment('p4', 7000)),
    ];
    expect(paidAgainstClaim(payments, 'c2'), 50000);
    expect(claimUnpaidRemainder(claim, payments), 35000);
  });

  testWidgets('hakediş detayı: kalan, kümülatif brüt sertifikadan değil bu hakedişin netinden hesaplanır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/subcontract-progress-claims/c2': [
        (
          status: 200,
          body: {
            'progress_claim': _claim('c2', 'HK-002', status: 'certified', net: 85000, cumulative: 300000),
            'items': <Object>[],
          },
        ),
      ],
      '/projects/p1/subcontracts/sc1': [
        (
          status: 200,
          body: {
            'subcontract': {'id': 'sc1', 'subcontract_no': 'TS-001', 'status': 'active', 'currency': 'TRY'},
            'items': <Object>[],
            'current_value': <String, Object>{},
          },
        ),
      ],
      '/projects/p1/subcontracts/sc1/payments': [
        (
          status: 200,
          body: {
            'payments': [
              _payment('p1', 50000, claimId: 'c2'),
              _payment('p2', 99999, claimId: 'c1'),
              _payment('p3', 10000, claimId: 'c2', voided: true),
            ],
          },
        ),
      ],
    });
    await _pump(
      tester,
      adapter,
      const ProgressClaimDetailScreen(projectId: 'p1', subcontractId: 'sc1', claimId: 'c2'),
    );

    expect(find.text('Ödenmemiş Kalan'), findsOneWidget);
    expect(find.text(Formatters.money(50000)), findsOneWidget, reason: 'bu hakedişe karşı ödenen');
    expect(find.text(Formatters.money(35000)), findsOneWidget, reason: '85.000 net − 50.000 ödenen');
    // Eski hesap: 300.000 kümülatif brüt − 50.000.
    expect(find.text(Formatters.money(250000)), findsNothing);
  });

  testWidgets('hakediş detayı: sertifikalanmamış hakedişte ödeme kalanı gösterilmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/subcontract-progress-claims/c3': [
        (
          status: 200,
          body: {'progress_claim': _claim('c3', 'HK-003', status: 'submitted', net: 40000), 'items': <Object>[]},
        ),
      ],
      '/projects/p1/subcontracts/sc1': [
        (
          status: 200,
          body: {
            'subcontract': {'id': 'sc1', 'subcontract_no': 'TS-001', 'status': 'active', 'currency': 'TRY'},
            'items': <Object>[],
            'current_value': <String, Object>{},
          },
        ),
      ],
      '/projects/p1/subcontracts/sc1/payments': [
        (status: 200, body: {'payments': <Object>[]}),
      ],
    });
    await _pump(
      tester,
      adapter,
      const ProgressClaimDetailScreen(projectId: 'p1', subcontractId: 'sc1', claimId: 'c3'),
    );

    expect(find.text('Ödenmemiş Kalan'), findsNothing);
  });

  testWidgets('ödeme formu: yalnızca sertifikalı hakedişler seçilebilir, seçilen progress_claim_id gönderilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/projects/p1/subcontracts/sc1/progress-claims': [
        (
          status: 200,
          body: {
            'progress_claims': [
              _claim('c1', 'HK-001', status: 'certified', net: 85000, cumulative: 100000),
              _claim('c2', 'HK-002', status: 'draft', net: 40000),
            ],
          },
        ),
      ],
      '/projects/p1/subcontracts/sc1/payments': [
        (status: 200, body: {'payments': [_payment('p1', 30000, claimId: 'c1')]}),
        (status: 201, body: _payment('p9', 55000, claimId: 'c1')),
      ],
    });
    await _pump(
      tester,
      adapter,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showSubcontractPaymentFormSheet(context, 'p1', 'sc1', currency: 'TRY'),
              child: const Text('Aç'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Aç'));
    await tester.pumpAndSettle();

    final picker = find.byKey(const ValueKey('taseron-odeme-hakedis'));
    expect(picker, findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.textContaining('HK-002'), findsNothing, reason: 'taslak hakedişe ödeme bağlanamaz');
    await tester.tap(find.textContaining('HK-001').last);
    await tester.pumpAndSettle();
    // Seçilen hakedişin kalanı görünür: 85.000 net − 30.000 ödenen.
    expect(find.textContaining('kalan ${Formatters.money(55000)}'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Ödenen Tutar (TRY)'), '55.000');
    final save = find.widgetWithText(ElevatedButton, 'Kaydet');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final post = adapter.requestBodies.whereType<Map<String, dynamic>>().single;
    expect(post['progress_claim_id'], 'c1');
    expect(post['amount'], 55000);
  });
}

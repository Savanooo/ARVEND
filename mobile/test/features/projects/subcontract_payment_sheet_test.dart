import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/projects/presentation/subcontract_payment_form_sheet.dart';

import '../../test_utils/fake_api_client.dart';

const _paymentsPath = '/projects/p1/subcontracts/sc1/payments';

const _created = (
  status: 201,
  body: {'id': 'pay1', 'amount': 1250.5, 'currency': 'TRY', 'paid_date': '2026-10-06', 'created_at': ''},
);

Future<void> _openSheet(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSubcontractPaymentFormSheet(context, 'p1', 'sc1', currency: 'TRY'),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Aç'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final save = find.widgetWithText(ElevatedButton, 'Kaydet');
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> _paymentBodies(FakeHttpClientAdapter adapter) => [
      for (var i = 0; i < adapter.calls.length; i++)
        if (adapter.calls[i] == _paymentsPath && adapter.requestBodies[i] is Map) adapter.requestBodies[i] as Map<String, dynamic>,
    ];

void main() {
  testWidgets('"1.250,50" bin iki yüz elli virgül elli gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      _paymentsPath: [_created],
    });
    await _openSheet(tester, adapter);

    await tester.enterText(find.widgetWithText(TextFormField, 'Ödenen Tutar (TRY)'), '1.250,50');
    await _save(tester);

    expect(_paymentBodies(adapter).single['amount'], 1250.5);
  });

  testWidgets('yanıtı kaybolan kayıt yeniden denenince AYNI idempotency anahtarı gider (mükerrer ödeme yok)', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      _paymentsPath: [
        (status: 503, body: {'error': 'Sunucuya ulaşılamadı'}),
        _created,
      ],
    });
    await _openSheet(tester, adapter);

    await tester.enterText(find.widgetWithText(TextFormField, 'Ödenen Tutar (TRY)'), '1250');
    await _save(tester);
    // İlk deneme başarısız: sayfa açık kalır, kullanıcı yeniden dener.
    expect(find.text('Taşeron Ödemesi Kaydet'), findsOneWidget);
    await _save(tester);

    final bodies = _paymentBodies(adapter);
    expect(bodies, hasLength(2));
    final key = bodies.first['idempotency_key'] as String;
    expect(key, isNotEmpty);
    expect(bodies.last['idempotency_key'], key);
    expect(find.text('Taşeron Ödemesi Kaydet'), findsNothing, reason: 'ikinci deneme başarılı, sayfa kapanır');
  });
}

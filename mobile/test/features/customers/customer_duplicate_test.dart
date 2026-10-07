import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/widgets/app_sheet.dart';
import 'package:arvend/features/customers/domain/customer.dart';
import 'package:arvend/features/customers/presentation/customer_form_sheet.dart';

import '../../test_utils/fake_api_client.dart';

/// Aynı vergi no/telefonla kayıtlı müşteri: backend 409 duplicate_customer
/// ile çakışanı döner. Mobil form web'deki gibi sorar: mevcut müşteriyi aç,
/// yine de kaydet (`allow_duplicate: true`) ya da vazgeç.

const _conflict = (
  status: 409,
  body: {
    'error': 'bu vergi numarasıyla kayıtlı bir müşteri zaten var: Moda Mimarlık',
    'code': 'duplicate_customer',
    'field': 'tax_number',
    'existing_customer': {'id': 'c9', 'name': 'Moda Mimarlık', 'is_active': true},
  },
);

Map<String, dynamic> _customer({String id = 'c1', String name = 'Moda Mimarlık Şube'}) => {
      'id': id, 'name': name, 'phone': '', 'email': '', 'address': '', 'tax_office': '',
      'tax_number': '1234567890', 'notes': '', 'is_active': true,
    };

/// Sheet'i gerçek bir go_router yığınında açar (müşteri detayına gidiş
/// görülebilsin).
Future<void> _pumpSheet(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  await tester.binding.setSurfaceSize(const Size(500, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (context, _) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showAppSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const CustomerFormSheet(),
            ),
            child: const Text('Yeni müşteri'),
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/diger/musteriler/:id',
      builder: (_, state) => Scaffold(body: Text('müşteri ${state.pathParameters['id']}')),
    ),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(client)],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.tap(find.text('Yeni müşteri'));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Ad *'), 'Moda Mimarlık Şube');
  await tester.enterText(find.widgetWithText(TextField, 'Vergi No'), '1234567890');
  await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
  await tester.pumpAndSettle();
}

void main() {
  test('DuplicateCustomer.fromError yalnızca 409 duplicate_customer\'ı tanır', () {
    final dup = DuplicateCustomer.fromError(ApiException(
      statusCode: 409,
      message: _conflict.body['error'] as String,
      kind: ApiErrorKind.conflict,
      code: 'duplicate_customer',
      body: _conflict.body,
    ))!;
    expect((dup.id, dup.name, dup.isActive, dup.field), ('c9', 'Moda Mimarlık', true, 'tax_number'));
    expect(
      DuplicateCustomer.fromError(
          const ApiException(statusCode: 409, message: 'çakışma', kind: ApiErrorKind.conflict)),
      isNull,
    );
    expect(DuplicateCustomer.fromError(StateError('x')), isNull);
  });

  testWidgets('409 sonrası diyalog mevcut müşteriyi gösterir; "Yine de kaydet" allow_duplicate ile tekrar gönderir',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers': [_conflict, (status: 201, body: _customer())],
    });
    await _pumpSheet(tester, adapter);

    expect(find.byKey(const ValueKey('customer-duplicate-dialog')), findsOneWidget);
    expect(find.text('Aynı vergi numarasıyla kayıtlı bir müşteri var:'), findsOneWidget);
    expect(find.text('Moda Mimarlık'), findsOneWidget);
    expect(adapter.requestBodies.first, isNot(contains('allow_duplicate')));

    await tester.tap(find.text('Yine de kaydet'));
    await tester.pumpAndSettle();

    expect(adapter.calls, ['/customers', '/customers']);
    expect((adapter.requestBodies[1] as Map)['allow_duplicate'], isTrue);
    // Kayıt başarılı: sheet kapandı.
    expect(find.text('Yeni Müşteri'), findsNothing);
  });

  testWidgets('"Vazgeç" formda kalır, ikinci istek atılmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers': [_conflict],
    });
    await _pumpSheet(tester, adapter);

    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(adapter.calls, ['/customers']);
    expect(find.text('Yeni Müşteri'), findsOneWidget);
    expect(find.byKey(const ValueKey('customer-duplicate-dialog')), findsNothing);
  });

  testWidgets('"Mevcut müşteriyi aç" sheet\'i kapatıp çakışan müşterinin detayına gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers': [_conflict],
    });
    await _pumpSheet(tester, adapter);

    await tester.tap(find.text('Mevcut müşteriyi aç'));
    await tester.pumpAndSettle();

    expect(find.text('müşteri c9'), findsOneWidget);
    expect(adapter.calls, ['/customers']);
  });

  testWidgets('kodsuz bir 409 diyalog açmaz, sunucu mesajı gösterilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers': [(status: 409, body: {'error': 'başka bir çakışma'})],
    });
    await _pumpSheet(tester, adapter);

    expect(find.byKey(const ValueKey('customer-duplicate-dialog')), findsNothing);
    expect(find.text('başka bir çakışma'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/customers/data/customers_repository.dart';
import 'package:arvend/features/customers/domain/customer.dart';
import 'package:arvend/features/customers/presentation/customer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart' show FakeAuth, testUser;

/// Pasif (arşivlenmiş) müşteri mobilden yeniden aktifleştirilebilir -- web
/// ile aynı uç: `PUT /customers/{id}` + `is_active: true`.

Map<String, dynamic> _customer({bool active = false}) => {
      'id': 'c1',
      'name': 'Ahmet İnşaat',
      'phone': '05551112233',
      'email': 'ahmet@example.com',
      'address': 'Örnek Mah. No:1',
      'tax_office': 'Kadıköy',
      'tax_number': '1234567890',
      'notes': 'VIP müşteri',
      'is_active': active,
    };

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Set<String> permissions) async {
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser(permissions))),
      ],
      child: const MaterialApp(home: CustomerDetailScreen(customerId: 'c1')),
    ),
  );
  await tester.pumpAndSettle();
}

/// Aktifleştirme de bir PUT'tur; sunucu 409 duplicate_customer dönerse
/// oluştur/düzenle formundaki çakışma diyaloğu açılmalı (ham mesaj değil).
const _conflict = (
  status: 409,
  body: {
    'error': 'bu vergi numarasıyla kayıtlı bir müşteri zaten var: Ahmet İnşaat A.Ş.',
    'code': 'duplicate_customer',
    'field': 'tax_number',
    'existing_customer': {'id': 'c9', 'name': 'Ahmet İnşaat A.Ş.', 'is_active': true},
  },
);

/// "Mevcut müşteriyi aç" gidişi görülebilsin diye gerçek bir go_router.
Future<void> _pumpRouted(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(initialLocation: '/diger/musteriler/c1', routes: [
    GoRoute(
      path: '/diger/musteriler/:id',
      builder: (_, state) => state.pathParameters['id'] == 'c1'
          ? const CustomerDetailScreen(customerId: 'c1')
          : Scaffold(body: Text('müşteri ${state.pathParameters['id']}')),
    ),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser({'customers.read', 'customers.manage'}))),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('customer-reactivate')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, 'Aktifleştir'));
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> _puts(FakeHttpClientAdapter adapter) => [
      for (var i = 0; i < adapter.calls.length; i++)
        if (adapter.methods[i] == 'PUT') adapter.requestBodies[i] as Map<String, dynamic>,
    ];

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  test('reactivate mevcut bilgileri aynen ve is_active=true ile PUT eder', () async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers/c1': [(status: 200, body: _customer(active: true))],
    });
    final repo = CustomersRepository(await buildFakeApiClient(adapter));

    final updated = await repo.reactivate(Customer.fromJson(_customer()));

    expect(adapter.calls.single, '/customers/c1');
    expect(adapter.requestBodies.single, {
      'name': 'Ahmet İnşaat',
      'phone': '05551112233',
      'email': 'ahmet@example.com',
      'address': 'Örnek Mah. No:1',
      'tax_office': 'Kadıköy',
      'tax_number': '1234567890',
      'notes': 'VIP müşteri',
      'is_active': true,
    });
    expect(updated.isActive, isTrue);
  });

  testWidgets('pasif müşteri detayında "Aktifleştir": onaydan sonra PUT atar', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers/c1': [
        (status: 200, body: _customer()),
        (status: 200, body: _customer(active: true)),
        (status: 200, body: _customer(active: true)),
      ],
    });
    await _pump(tester, adapter, {'customers.read', 'customers.manage'});

    expect(find.byIcon(Icons.archive_outlined), findsNothing);
    await tester.tap(find.byKey(const ValueKey('customer-reactivate')));
    await tester.pumpAndSettle();
    expect(find.text('Müşteriyi Aktifleştir'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Aktifleştir'));
    await tester.pumpAndSettle();

    final put = adapter.requestBodies.whereType<Map<String, dynamic>>().single;
    expect(put['is_active'], isTrue);
    expect(find.text('Müşteri aktifleştirildi.'), findsOneWidget);
    // Detay tazelendi: artık aktif, pasifleştirme düğmesi geri geldi.
    expect(find.byIcon(Icons.archive_outlined), findsOneWidget);
  });

  testWidgets('yalnızca okuma izni: aktifleştirme düğmesi yok', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers/c1': [(status: 200, body: _customer())],
    });
    await _pump(tester, adapter, {'customers.read'});

    expect(find.byKey(const ValueKey('customer-reactivate')), findsNothing);
  });

  testWidgets('aktifleştirmede 409 duplicate: çakışma diyaloğu; "Yine de kaydet" allow_duplicate ile tekrar PUT eder',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers/c1': [
        (status: 200, body: _customer()),
        _conflict,
        (status: 200, body: _customer(active: true)),
        (status: 200, body: _customer(active: true)),
      ],
    });
    await _pumpRouted(tester, adapter);

    expect(find.byKey(const ValueKey('customer-duplicate-dialog')), findsOneWidget);
    expect(find.text('Ahmet İnşaat A.Ş.'), findsOneWidget);
    expect(find.text(_conflict.body['error'] as String), findsNothing, reason: 'ham sunucu mesajı değil');

    await tester.tap(find.text('Yine de kaydet'));
    await tester.pumpAndSettle();

    final puts = _puts(adapter);
    expect(puts, hasLength(2));
    expect(puts.first.containsKey('allow_duplicate'), isFalse);
    expect(puts.last['allow_duplicate'], isTrue);
    expect(puts.last['is_active'], isTrue);
    expect(find.text('Müşteri aktifleştirildi.'), findsOneWidget);
    expect(find.byIcon(Icons.archive_outlined), findsOneWidget);
  });

  testWidgets('aktifleştirmede 409 duplicate: "Mevcut müşteriyi aç" çakışanın detayına gider, ikinci PUT yok',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers/c1': [(status: 200, body: _customer()), _conflict],
    });
    await _pumpRouted(tester, adapter);

    await tester.tap(find.text('Mevcut müşteriyi aç'));
    await tester.pumpAndSettle();

    expect(find.text('müşteri c9'), findsOneWidget);
    expect(_puts(adapter), hasLength(1));
  });

  testWidgets('aktifleştirmede 409 duplicate: "Vazgeç" pasif bırakır, ikinci PUT yok', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers/c1': [(status: 200, body: _customer()), _conflict],
    });
    await _pumpRouted(tester, adapter);

    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(_puts(adapter), hasLength(1));
    expect(find.byKey(const ValueKey('customer-duplicate-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('customer-reactivate')), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/projects/presentation/form_number_input.dart';
import 'package:arvend/features/projects/presentation/purchase_order_form_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_request_form_screen.dart';

import '../../test_utils/fake_api_client.dart';

/// Satın alma / taşeron formlarında Türkçe tutar girişi: "1.250" bin iki yüz
/// elli, "1.250,50" bin iki yüz elli virgül elli okunur; geçersiz ya da yarım
/// bir kalem satırı SESSİZCE atlanmaz, satırda hata gösterip kaydı durdurur.

const _suppliers = (
  status: 200,
  body: {
    'suppliers': [
      {'id': 's1', 'code': 'T-001', 'legal_name': 'Demir Çelik A.Ş.', 'trade_name': '', 'is_active': true},
    ],
  },
);

const _costCodes = (
  status: 200,
  body: {
    'cost_codes': [
      {'id': 'cc1', 'code': '01.01', 'name': 'Genel Giderler', 'is_active': true},
    ],
  },
);

Map<String, dynamic> _po({String id = 'po1'}) => {
      'id': id,
      'po_no': 'PO-2026-0001',
      'supplier_id': 's1',
      'status': 'draft',
      'currency': 'TRY',
      'tax_rate': 20,
    };

/// Formu gerçek bir go_router yığınında açar: ana sayfa -> form (push).
Future<void> _pumpRouted(
  WidgetTester tester,
  FakeHttpClientAdapter adapter, {
  required Widget form,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () => context.push('/form'), child: const Text('Aç')),
          ),
        ),
      ),
      GoRoute(path: '/form', builder: (_, _) => form),
      GoRoute(
        path: '/projeler/:id/satin-alma/siparisler/:poId',
        builder: (_, state) => Scaffold(body: Text('PO detay ${state.pathParameters['poId']}')),
      ),
      GoRoute(
        path: '/projeler/:id/satin-alma/talepler/:prId',
        builder: (_, state) => Scaffold(body: Text('Talep detay ${state.pathParameters['prId']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.tap(find.text('Aç'));
  await tester.pumpAndSettle();
}

Future<void> _pickDropdown(WidgetTester tester, Finder field, String option) async {
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  final button = find.widgetWithText(ElevatedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  group('form_number_input', () {
    test('Türkçe binlik nokta ve ondalık virgül', () {
      expect(parseFormNumber('1.250'), 1250);
      expect(parseFormNumber('1.250,50'), 1250.5);
      expect(parseFormNumber('12.500'), 12500);
      expect(parseFormNumber('12,5'), 12.5);
      expect(parseFormNumber('12.5'), 12.5);
      expect(parseFormNumber(''), isNull);
      expect(parseFormNumber('abc'), isNull);
    });

    test('mevcut değer alana geri okunabilir biçimde yazılır', () {
      // toString() "1.13" yazardı; "1.125" ise geri okununca 1125 olurdu.
      expect(formNumberText(1250.5), '1250,5');
      expect(formNumberText(1.13), '1,13');
      expect(parseFormNumber(formNumberText(1.13)), 1.13);
      expect(formNumberText(null), '');
    });

    test('formNumberError: zorunlu, sıfır ve biçim', () {
      expect(formNumberError('1.250,50'), isNull);
      expect(formNumberError(''), 'Zorunlu');
      expect(formNumberError('', required: false), isNull);
      expect(formNumberError('0'), 'Sıfırdan büyük olmalı');
      expect(formNumberError('0', allowZero: true), isNull);
      expect(formNumberError('1,2,3'), isNotNull);
      expect(formNumberError('-5'), 'Negatif değer girilemez.');
    });

    test('yüzde: binlik gruplama yok, 0-100 arası', () {
      expect(parseFormPercent('18.5'), 18.5);
      expect(parseFormPercent('20'), 20);
      expect(formPercentError(''), isNull);
      expect(formPercentError('33.333'), isNotNull);
      expect(formPercentError('120'), 'Oran en fazla %100 olabilir.');
    });
  });

  testWidgets('satın alma siparişi: "1.250" miktar ve "1.250,50" fiyat doğru gider, boş satır atlanır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/suppliers': [_suppliers],
      '/organization/cost-codes': [_costCodes],
      '/projects/p1/purchase-orders': [(status: 201, body: _po())],
    });
    await _pumpRouted(tester, adapter, form: const PurchaseOrderFormScreen(projectId: 'p1'));

    await _pickDropdown(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Tedarikçi'), 'T-001 — Demir Çelik A.Ş.');
    await _pickDropdown(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Maliyet Kodu'), '01.01 — Genel Giderler');
    await tester.enterText(_field('Açıklama'), 'Nervürlü demir');
    await tester.enterText(_field('Miktar'), '1.250');
    await tester.enterText(_field('Birim Fiyat'), '1.250,50');
    // Hiç dokunulmamış ikinci satır gönderilmez.
    await tester.tap(find.text('Kalem Ekle'));
    await tester.pumpAndSettle();

    await _tapButton(tester, 'Siparişi Oluştur');

    final i = adapter.calls.indexOf('/projects/p1/purchase-orders');
    expect(i, isNonNegative, reason: 'geçerli form gönderilmeli');
    final body = adapter.requestBodies[i] as Map<String, dynamic>;
    final items = body['items'] as List;
    expect(items, hasLength(1));
    expect(items.single['quantity'], 1250);
    expect(items.single['unit_price'], 1250.5);
    expect(body['tax_rate'], 20);
  });

  testWidgets('satın alma siparişi: yarım ya da geçersiz satır satırda hata gösterir, istek atılmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/suppliers': [_suppliers],
      '/organization/cost-codes': [_costCodes],
    });
    await _pumpRouted(tester, adapter, form: const PurchaseOrderFormScreen(projectId: 'p1'));

    await _pickDropdown(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Tedarikçi'), 'T-001 — Demir Çelik A.Ş.');
    // Maliyet kodu seçilmemiş, fiyat okunamıyor ("1,2,3").
    await tester.enterText(_field('Açıklama'), 'Nervürlü demir');
    await tester.enterText(_field('Miktar'), '10');
    await tester.enterText(_field('Birim Fiyat'), '1,2,3');

    await _tapButton(tester, 'Siparişi Oluştur');

    expect(find.text('Maliyet kodu seçin'), findsOneWidget);
    expect(find.text('Geçerli bir sayı gir (ör. 1.250 veya 1250,50).'), findsOneWidget);
    expect(adapter.calls, isNot(contains('/projects/p1/purchase-orders')));
  });

  testWidgets('satın alma talebi: "12.500" tahmini fiyat on iki bin beş yüz gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/cost-codes': [_costCodes],
      '/projects/p1/purchase-requests': [
        (status: 201, body: {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir', 'status': 'draft'}),
      ],
    });
    await _pumpRouted(tester, adapter, form: const PurchaseRequestFormScreen(projectId: 'p1'));

    await tester.enterText(_field('Başlık'), 'Demir ihtiyacı');
    await tester.enterText(_field('Açıklama').last, 'Nervürlü demir');
    await tester.enterText(_field('Miktar'), '2,5');
    await tester.enterText(_field('Tahmini Br. Fiyat'), '12.500');

    await _tapButton(tester, 'Talebi Oluştur');

    final i = adapter.calls.indexOf('/projects/p1/purchase-requests');
    expect(i, isNonNegative);
    final item = ((adapter.requestBodies[i] as Map<String, dynamic>)['items'] as List).single as Map<String, dynamic>;
    expect(item['quantity'], 2.5);
    expect(item['estimated_unit_cost'], 12500);
  });
}

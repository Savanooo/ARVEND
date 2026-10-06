import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/projects/presentation/form_number_input.dart';
import 'package:arvend/features/projects/presentation/purchase_order_form_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_request_form_screen.dart';

import '../../test_utils/fake_api_client.dart';
import 'form_test_support.dart';

/// Satın alma / taşeron formlarında Türkçe tutar girişi: "1.250" bin iki yüz
/// elli, "1.250,50" bin iki yüz elli virgül elli okunur; geçersiz ya da yarım
/// bir kalem satırı SESSİZCE atlanmaz, satırda hata gösterip kaydı durdurur.

Map<String, dynamic> _po({String id = 'po1'}) => {
      'id': id,
      'po_no': 'PO-2026-0001',
      'supplier_id': 's1',
      'status': 'draft',
      'currency': 'TRY',
      'tax_rate': 20,
    };

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
      '/organization/suppliers': [kSuppliersResponse],
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1': [kProjectResponse],
      '/projects/p1/purchase-orders': [(status: 201, body: _po())],
    });
    await pumpRoutedForm(tester, adapter, form: const PurchaseOrderFormScreen(projectId: 'p1'));

    await pickDropdown(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Tedarikçi'), 'T-001 — Demir Çelik A.Ş.');
    await pickDropdown(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Maliyet Kodu'), '01.01 — Genel Giderler');
    await tester.enterText(formField('Açıklama'), 'Nervürlü demir');
    await tester.enterText(formField('Miktar'), '1.250');
    await tester.enterText(formField('Birim Fiyat'), '1.250,50');
    // Hiç dokunulmamış ikinci satır gönderilmez.
    await tester.tap(find.text('Kalem Ekle'));
    await tester.pumpAndSettle();

    await tapButton(tester, 'Siparişi Oluştur');

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
      '/organization/suppliers': [kSuppliersResponse],
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1': [kProjectResponse],
    });
    await pumpRoutedForm(tester, adapter, form: const PurchaseOrderFormScreen(projectId: 'p1'));

    await pickDropdown(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Tedarikçi'), 'T-001 — Demir Çelik A.Ş.');
    // Maliyet kodu seçilmemiş, fiyat okunamıyor ("1,2,3").
    await tester.enterText(formField('Açıklama'), 'Nervürlü demir');
    await tester.enterText(formField('Miktar'), '10');
    await tester.enterText(formField('Birim Fiyat'), '1,2,3');

    await tapButton(tester, 'Siparişi Oluştur');

    expect(find.text('Maliyet kodu seçin'), findsOneWidget);
    expect(find.text('Geçerli bir sayı gir (ör. 1.250 veya 1250,50).'), findsOneWidget);
    expect(adapter.calls, isNot(contains('/projects/p1/purchase-orders')));
  });

  testWidgets('satın alma talebi: "12.500" tahmini fiyat on iki bin beş yüz gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1/purchase-requests': [
        (status: 201, body: {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir', 'status': 'draft'}),
      ],
    });
    await pumpRoutedForm(tester, adapter, form: const PurchaseRequestFormScreen(projectId: 'p1'));

    await tester.enterText(formField('Başlık'), 'Demir ihtiyacı');
    await tester.enterText(formField('Açıklama').last, 'Nervürlü demir');
    await tester.enterText(formField('Miktar'), '2,5');
    await tester.enterText(formField('Tahmini Br. Fiyat'), '12.500');

    await tapButton(tester, 'Talebi Oluştur');

    final i = adapter.calls.indexOf('/projects/p1/purchase-requests');
    expect(i, isNonNegative);
    final item = ((adapter.requestBodies[i] as Map<String, dynamic>)['items'] as List).single as Map<String, dynamic>;
    expect(item['quantity'], 2.5);
    expect(item['estimated_unit_cost'], 12500);
  });
}

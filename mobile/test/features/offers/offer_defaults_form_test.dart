import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Yeni teklif formu firma varsayılanlarını (GET /offers/defaults) kullanır:
/// KDV önceden dolar ve düzenlenebilir, formda alanı olmayan geçerlilik sonu
/// bilgi olarak görünür (kayıtta null gider, sunucu firma süresini yazar).
/// Fiyatı 0 olan kalem sessizce kaydedilmez, onay istenir.

final _user = testUser({'offers.read', 'offers.create', 'offers.update', 'customers.read'});

Map<String, dynamic> _offer({String id = 'o9'}) => {
      'id': id,
      'offer_no': 'TKF-009',
      'revision_no': 0,
      'customer_id': null,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-10-07',
      'valid_until': null,
      'subtotal': 0,
      'vat_rate': 10,
      'vat_amount': 0,
      'grand_total': 0,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
      'items': <Object>[],
    };

const _defaults = (
  status: 200,
  body: {
    'vat_rate': 10,
    'currency': 'TRY',
    'validity_days': 30,
    'valid_until': '2026-11-06',
    'payment_terms': '',
    'delivery_terms': '',
    'footer': '',
  },
);

Finder _itemField(String label, {int index = 0}) => formField(label).at(index);

TextField _textField(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.descendant(of: formField(label), matching: find.byType(TextField)));

Future<void> _fillOneItem(WidgetTester tester, {String price = '100'}) async {
  await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
  await tester.enterText(_itemField('Ürün / Hizmet Adı'), 'Alçıpan');
  await tester.enterText(_itemField('Miktar'), '2');
  await tester.enterText(_itemField('Birim Fiyat'), price);
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  test('OfferDefaults.fromJson: süre yoksa null, eksik alanlar sunucu varsayılanı', () {
    final d = OfferDefaults.fromJson({'vat_rate': 18, 'currency': 'USD', 'validity_days': null, 'valid_until': null});
    expect(d.vatRate, 18);
    expect(d.currency, 'USD');
    expect(d.validityDays, isNull);
    expect(d.validUntil, isNull);
    final empty = OfferDefaults.fromJson(const {});
    expect(empty.vatRate, 20);
    expect(empty.currency, 'TRY');
    expect(currencyLabel('TRY'), 'TL');
    expect(currencyLabel('EUR'), 'EUR');
  });

  testWidgets('KDV firma varsayılanıyla dolar, geçerlilik sonu bilgi olarak görünür; tarih gönderilmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [_defaults],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    expect(_textField(tester, 'KDV Oranı (%)').controller!.text, '10');
    expect(find.text('Geçerlilik sonu: 06.11.2026 (firma ayarı: 30 gün)'), findsOneWidget);

    await _fillOneItem(tester);
    await tapButton(tester, 'Teklifi Oluştur');

    final body = requestBodyFor(adapter, '/offers/');
    expect(body['vat_rate'], 10);
    // Formda geçerlilik alanı yok: null gider, sunucu firma süresini uygular.
    expect(body['valid_until'], isNull);
    expect(body.containsKey('currency'), isFalse);
  });

  testWidgets('varsayılan KDV düzenlenebilir: elle girilen oran gönderilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [_defaults],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    await tester.enterText(formField('KDV Oranı (%)'), '1');
    await _fillOneItem(tester);
    await tapButton(tester, 'Teklifi Oluştur');

    expect(requestBodyFor(adapter, '/offers/')['vat_rate'], 1);
  });

  testWidgets('varsayılanlar okunamazsa form %20 ile açılır ve kayıt yine yapılır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [(status: 403, body: {'error': 'bu işlem için yetkiniz yok'})],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    expect(_textField(tester, 'KDV Oranı (%)').controller!.text, '20');
    expect(find.byKey(const ValueKey('offer-defaults-info')), findsNothing);
    await _fillOneItem(tester);
    await tapButton(tester, 'Teklifi Oluştur');
    expect(requestBodyFor(adapter, '/offers/')['vat_rate'], 20);
  });

  testWidgets('düzenlemede varsayılanlar istenmez (mevcut KDV korunur)', (tester) async {
    final existing = _offer(id: 'o1')
      ..['vat_rate'] = 18
      ..['items'] = [
        {'id': 'i1', 'product_name': 'Alçıpan', 'quantity': 1, 'unit_price': 100, 'line_total': 100, 'unit': 'm2'},
      ];
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: existing), (status: 200, body: existing)],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(offerId: 'o1'), user: _user);

    expect(_textField(tester, 'KDV Oranı (%)').controller!.text, '18');
    await tapButton(tester, 'Kaydet');
    expect(adapter.calls, isNot(contains('/offers/defaults')));
    expect(requestBodyFor(adapter, '/offers/o1')['vat_rate'], 18);
  });

  testWidgets('fiyatı 0 olan kalem onaysız kaydedilmez; "Yine de Kaydet" ile gider', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [_defaults],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    await _fillOneItem(tester, price: '0');
    await tapButton(tester, 'Teklifi Oluştur');

    expect(find.text('1 kalemin fiyatı 0 TL. Yine de kaydedilsin mi?'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/')));

    await tapButton(tester, 'Teklifi Oluştur');
    await tester.tap(find.text('Yine de Kaydet'));
    await tester.pumpAndSettle();
    final items = (requestBodyFor(adapter, '/offers/')['items'] as List).cast<Map<String, dynamic>>();
    expect(items.single['unit_price'], 0);
  });

  testWidgets('fiyatlı kalemlerde onay sorulmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [_defaults],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    await _fillOneItem(tester);
    await tapButton(tester, 'Teklifi Oluştur');
    expect(find.byKey(const ValueKey('offer-zero-price-confirm')), findsNothing);
    expect(adapter.calls, contains('/offers/'));
  });
}

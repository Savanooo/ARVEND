import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklif formu: Türkçe tutar girişi ("12.500" on iki bin beş yüz), satır
/// bazlı hata, canlı ara toplam / KDV / toplam önizlemesi; kayıtlı müşteriye
/// bağlıyken müşteri alanları salt okunur ve bağ kaldırılabilir.

final _user = testUser({'offers.read', 'offers.create', 'offers.update', 'customers.read'});

Map<String, dynamic> _offer({String id = 'o9', String? validUntil}) => {
      'id': id,
      'offer_no': 'TKF-009',
      'revision_no': 0,
      'customer_id': null,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-10-06',
      'valid_until': validUntil,
      'subtotal': 0,
      'vat_rate': 20,
      'vat_amount': 0,
      'grand_total': 0,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
      'items': <Object>[],
    };

const _customers = (
  status: 200,
  body: {
    'customers': [
      {
        'id': 'c1', 'name': 'Moda Mimarlık', 'phone': '5551112233', 'email': 'info@moda.com',
        'address': 'Kadıköy', 'tax_office': '', 'tax_number': '', 'notes': '', 'is_active': true,
      },
    ],
  },
);

/// [index]. kalem kartındaki [label] etiketli alan (kalem kartları sırayla).
Finder _itemField(String label, {int index = 0}) => formField(label).at(index);

TextField _textField(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.descendant(of: formField(label), matching: find.byType(TextField)));

void main() {
  testWidgets('"12.500" birim fiyat on iki bin beş yüz gider; önizleme ara toplam / KDV / toplamı gösterir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await tester.enterText(_itemField('Ürün / Hizmet Adı'), 'Alçıpan');
    await tester.enterText(_itemField('Miktar'), '2');
    await tester.enterText(_itemField('Birim Fiyat'), '12.500');
    await tester.tap(find.text('Kalem Ekle'));
    await tester.pumpAndSettle();
    await tester.enterText(_itemField('Ürün / Hizmet Adı', index: 1), 'Boya');
    await tester.enterText(_itemField('Miktar', index: 1), '1');
    await tester.enterText(_itemField('Birim Fiyat', index: 1), '1.250,50');
    // Hiç dokunulmamış üçüncü satır gönderilmez.
    await tester.tap(find.text('Kalem Ekle'));
    await tester.pumpAndSettle();

    // 2 x 12.500 + 1 x 1.250,50 = 26.250,50; %20 KDV = 5.250,10.
    expect(find.text('Satır toplamı: ${Formatters.money(25000)}'), findsOneWidget);
    final preview = find.byKey(const ValueKey('offer-totals-preview'));
    expect(find.descendant(of: preview, matching: find.text(Formatters.money(26250.5))), findsOneWidget);
    expect(find.descendant(of: preview, matching: find.text(Formatters.money(5250.1))), findsOneWidget);
    expect(find.descendant(of: preview, matching: find.text(Formatters.money(31500.6))), findsOneWidget);

    await tapButton(tester, 'Teklifi Oluştur');

    final body = requestBodyFor(adapter, '/offers/');
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(2));
    expect(items[0]['unit_price'], 12500);
    expect(items[0]['quantity'], 2);
    expect(items[1]['unit_price'], 1250.5);
    expect(body['vat_rate'], 20);
  });

  testWidgets('okunamayan fiyatlı satır sessizce atlanmaz: satırda hata, istek yok', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {});
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await tester.enterText(_itemField('Ürün / Hizmet Adı'), 'Alçıpan');
    await tester.enterText(_itemField('Miktar'), '2');
    await tester.enterText(_itemField('Birim Fiyat'), '1,2,3');
    await tapButton(tester, 'Teklifi Oluştur');

    expect(find.text('Geçerli bir sayı gir (ör. 1.250 veya 1250,50).'), findsOneWidget);
    expect(adapter.calls, isNot(contains('/offers/')));
  });

  testWidgets('kayıtlı müşteri seçilince alanlar salt okunur; "Bağlantıyı kaldır" ile serbest metne döner', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers': [_customers],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _user);

    await tester.tap(find.text('Seç'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moda Mimarlık'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Kayıtlı müşteriye bağlı'), findsOneWidget);
    for (final label in ['Müşteri Adı', 'Telefon (opsiyonel)', 'E-posta (opsiyonel)', 'Adres (opsiyonel)']) {
      expect(_textField(tester, label).enabled, isFalse, reason: '$label bağlıyken düzenlenemez');
    }

    await tester.tap(find.byKey(const ValueKey('offer-customer-unlink')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kayıtlı müşteriye bağlı'), findsNothing);
    expect(_textField(tester, 'Müşteri Adı').enabled, isTrue);

    await tester.enterText(formField('Müşteri Adı'), 'Moda Mimarlık Şantiye');
    await tester.enterText(_itemField('Ürün / Hizmet Adı'), 'Alçıpan');
    await tester.enterText(_itemField('Miktar'), '1');
    await tester.enterText(_itemField('Birim Fiyat'), '100');
    await tapButton(tester, 'Teklifi Oluştur');

    final body = requestBodyFor(adapter, '/offers/');
    expect(body['customer_id'], isNull);
    expect(body['customer_name'], 'Moda Mimarlık Şantiye');
  });

  testWidgets('teklifi düzenlemek geçerlilik tarihini silmez', (tester) async {
    final existing = _offer(id: 'o1', validUntil: '2026-11-30')
      ..['items'] = [
        {'id': 'i1', 'product_name': 'Alçıpan', 'quantity': 3, 'unit_price': 1250.5, 'line_total': 3751.5, 'unit': 'm2'},
      ];
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [
        (status: 200, body: existing),
        (status: 200, body: _offer(id: 'o1', validUntil: '2026-11-30')),
      ],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(offerId: 'o1'), user: _user);

    // Mevcut değer alana geri okunabilir biçimde yazılır ("1250,5").
    expect(find.text('1250,5'), findsOneWidget);
    await tapButton(tester, 'Kaydet');

    final body = requestBodyFor(adapter, '/offers/o1');
    expect(body['valid_until'], '2026-11-30');
    expect(((body['items'] as List).single as Map)['unit_price'], 1250.5);
  });
}

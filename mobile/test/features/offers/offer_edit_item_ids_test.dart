import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Düzenlemede kayıtlı kalemler id'leriyle geri gönderilir. İç fiyatlama
/// yetkisi olmayan düzenleyicide (ör. "Eski Sistem" rolü) sunucu kalemlerin
/// iç maliyetini bu id ile taşır; mobil id göndermediği için iç maliyetli bir
/// taslak mobilden hiç kaydedilemiyordu (409 "eşleştirilemedi").

Map<String, dynamic> _item(String id, String name, num qty, num price, {Map<String, dynamic>? internal}) => {
  'id': id,
  'product_name': name,
  'quantity': qty,
  'unit_price': price,
  'line_total': qty * price,
  'unit': 'm2',
  'internal_pricing': ?internal,
};

Map<String, dynamic> _draft(List<Map<String, dynamic>> items) => {
  'id': 'o1',
  'offer_no': 'TKF-001',
  'revision_no': 0,
  'customer_id': null,
  'customer_name': 'Ali Veli',
  'offer_date': '2026-10-01',
  'valid_until': null,
  'subtotal': 0,
  'vat_rate': 20,
  'vat_amount': 0,
  'grand_total': 0,
  'notes': '',
  'status': 'taslak',
  'is_passive': false,
  'items': items,
};

List<Map<String, dynamic>> _sentItems(FakeHttpClientAdapter adapter) =>
    (requestBodyFor(adapter, '/offers/o1')['items'] as List).cast<Map<String, dynamic>>();

void main() {
  test('toJson: kayıtlı kalemde id gider, yeni/metraj satırında hiç yazılmaz', () {
    OfferItem item(String id) => OfferItem(
      id: id,
      productId: null,
      productName: 'Alçıpan',
      quantity: 1,
      unitPrice: 100,
      lineTotal: 100,
      unit: 'm2',
      sectionLabel: null,
      calcCategoryId: null,
      calcSnapshot: null,
    );
    expect(item('i1').toJson()['id'], 'i1');
    expect(item('').toJson().containsKey('id'), isFalse);
  });

  testWidgets('iç fiyatlama yetkisi olmayan düzenleyici: kalemler id ile gider, iç alan gönderilmez', (tester) async {
    // Sunucu iç maliyeti bu kullanıcıya hiç göstermez (internal_pricing yok);
    // kayıtta id ile eşleyip korur.
    final draft = _draft([_item('i1', 'Alçıpan', 3, 100), _item('i2', 'Boya', 1, 50)]);
    final adapter = FakeHttpClientAdapter(
      script: {
        '/offers/o1': [(status: 200, body: draft), (status: 200, body: draft)],
      },
    );
    final probe = await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(offerId: 'o1'),
      user: testUser({'offers.read', 'offers.update'}),
    );

    await tester.enterText(formField('Miktar').at(0), '4');
    await tester.tap(find.text('Kalem Ekle'));
    await tester.pumpAndSettle();
    await tester.enterText(formField('Ürün / Hizmet Adı').at(2), 'İşçilik');
    await tester.enterText(formField('Miktar').at(2), '1');
    await tester.enterText(formField('Birim Fiyat').at(2), '200');
    await tapButton(tester, 'Kaydet');

    final items = _sentItems(adapter);
    expect(items.map((i) => i['id']), ['i1', 'i2', null]);
    expect(items[0]['quantity'], 4);
    expect(items[2].containsKey('id'), isFalse, reason: 'yeni satır id taşımaz');
    for (final i in items) {
      expect(i.containsKey('internal_subcontract_cost'), isFalse);
      expect(i.containsKey('pricing_mode'), isFalse);
    }
    expect(probe.completed, isTrue, reason: 'kayıt başarılı, form kapandı');
  });

  testWidgets('silinen kalemin id\'si gitmez; kalanlar kendi id\'sini taşır', (tester) async {
    final draft = _draft([_item('i1', 'Alçıpan', 3, 100), _item('i2', 'Boya', 1, 50)]);
    final adapter = FakeHttpClientAdapter(
      script: {
        '/offers/o1': [(status: 200, body: draft), (status: 200, body: draft)],
      },
    );
    await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(offerId: 'o1'),
      user: testUser({'offers.read', 'offers.update'}),
    );

    // İlk kalem kartının kapat (x) düğmesi.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    await tapButton(tester, 'Kaydet');

    final items = _sentItems(adapter);
    expect(items.map((i) => i['id']), ['i2']);
  });

  testWidgets('iç fiyatlama yöneticisi: id ve iç alanlar birlikte gider', (tester) async {
    final draft = _draft([
      _item(
        'i1',
        'Çatı',
        1,
        91000,
        internal: {
          'cost': 70000,
          'pricing_mode': 'markup',
          'markup_percent': 30,
          'expected_profit': 21000,
          'effective_markup_percent': 30,
        },
      ),
    ]);
    final adapter = FakeHttpClientAdapter(
      script: {
        '/offers/o1': [(status: 200, body: draft), (status: 200, body: draft)],
      },
    );
    await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(offerId: 'o1'),
      user: testUser({
        'offers.read',
        'offers.update',
        kPermOffersInternalPricingRead,
        kPermOffersInternalPricingManage,
      }),
    );

    await tapButton(tester, 'Kaydet');

    final item = _sentItems(adapter).single;
    expect(item['id'], 'i1');
    expect(item['internal_subcontract_cost'], 70000);
    expect(item['pricing_mode'], 'markup');
    expect(item['markup_percent'], 30);
  });
}

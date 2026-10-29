import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';
import 'package:arvend/features/offers/presentation/offer_revision_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklif kaleminin "Maliyet ve Kâr" bölümü ("Markup ve satış yerini kimse
/// anlamıyor"): sade etiketler, her iki modda canlı sonuç (sunucunun
/// yuvarlamasıyla), anlaşılır doğrulama, detay ve revizyonda aynı sözcükler.
/// API değerleri (`markup` / `manual`) değişmedi.

final _manager = testUser({
  'offers.read',
  'offers.create',
  'offers.update',
  kPermOffersInternalPricingRead,
  kPermOffersInternalPricingManage,
});

Map<String, dynamic> _offer({List<Map<String, dynamic>> items = const []}) => {
      'id': 'o1',
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_id': null,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-10-06',
      'valid_until': null,
      'subtotal': 11500,
      'vat_rate': 20,
      'vat_amount': 2300,
      'grand_total': 13800,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
      'items': items,
    };

Map<String, dynamic> _item({
  String id = 'i1',
  String mode = 'markup',
  num cost = 1000,
  num price = 1150,
  num? markup = 15,
  num qty = 10,
}) =>
    {
      'id': id,
      'product_name': 'Seramik döşeme',
      'quantity': qty,
      'unit_price': price,
      'line_total': qty * price,
      'unit': 'm²',
      'internal_pricing': {
        'cost': cost,
        'pricing_mode': mode,
        'markup_percent': ?markup,
        'expected_profit': price - cost,
        'effective_markup_percent': (price - cost) * 100 / cost,
      },
    };

Finder _result() => find.byKey(const ValueKey('offer-pricing-result'));

/// Ekrandaki metin, bölünmez boşluklar düz boşluğa çevrilmiş (sonuç ve
/// özet satırları parçaları bölünmesin diye U+00A0 kullanır).
String _plain(Text t) => (t.textSpan?.toPlainText() ?? t.data ?? '').replaceAll('\u00a0', ' ');

String _resultText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: _result(), matching: find.byType(Text)))
    .map(_plain)
    .join('\n');

Finder _line(String text) => find.byWidgetPredicate((w) => w is Text && _plain(w) == text, description: text);

Future<FakeHttpClientAdapter> _openNew(WidgetTester tester) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/offers/': [(status: 201, body: _offer())],
  });
  await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _manager);
  await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
  await tester.enterText(formField('Ürün / Hizmet Adı'), 'Seramik döşeme');
  await tester.enterText(formField('Miktar'), '10');
  await tester.pump();
  return adapter;
}

Future<void> _pickMode(WidgetTester tester, String label) =>
    pickDropdown(tester, find.byKey(const ValueKey('offer-pricing-mode')), label);

Map<String, dynamic> _sentItem(FakeHttpClientAdapter adapter, String path) =>
    (requestBodyFor(adapter, path)['items'] as List).cast<Map<String, dynamic>>().single;

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('form', () {
    testWidgets('sade etiketler; yeni kalem "Satış fiyatını ben gireyim" açılır', (tester) async {
      await _openNew(tester);

      expect(find.text('Maliyet ve Kâr'), findsOneWidget);
      expect(find.text('Müşteri görmez'), findsOneWidget);
      expect(find.text('Fiyat nasıl belirlensin?'), findsOneWidget);
      expect(find.text('Satış fiyatını ben gireyim').hitTestable(), findsOneWidget);
      expect(find.text('Müşteri fiyatını sen yazarsın; kârın hesaplanır'), findsOneWidget);
      expect(formField('Bize maliyeti (birim)'), findsOneWidget);
      expect(formField('Kâr oranı (%)'), findsNothing, reason: 'elle fiyatta oran sorulmaz');
      expect(formField('Birim Fiyat'), findsOneWidget);
      // Eski jargon hiçbir yerde yok.
      for (final old in ['İç Fiyatlandırma', 'Fiyat Modu', 'Markup', 'Markup %', 'Manuel satış', 'İç taşeron maliyeti']) {
        expect(find.text(old), findsNothing, reason: old);
      }
      expect(find.textContaining('sunucu kesinleştirir'), findsNothing);
      expect(find.textContaining('önizleme'), findsNothing);

      // Menüde her seçeneğin altında tek satır açıklama.
      await tester.tap(find.byKey(const ValueKey('offer-pricing-mode')));
      await tester.pumpAndSettle();
      expect(find.text('Maliyetin üstüne kâr yüzdesi eklenir'), findsOneWidget);
      expect(find.text('Bu kalemde maliyet ve kâr tutulmaz'), findsOneWidget);
      expect(find.text('Kâr oranıyla hesapla').hitTestable(), findsOneWidget);
      expect(find.text('Kullanma').hitTestable(), findsOneWidget);
    });

    testWidgets('satış fiyatını ben gireyim: fiyat ve maliyetten canlı kâr; maliyet boşsa iç alan gitmez', (tester) async {
      final adapter = await _openNew(tester);

      await tester.enterText(formField('Birim Fiyat'), '1.150');
      await tester.pump();
      expect(_resultText(tester), contains('Müşteriye birim fiyat: 1.150,00 TL · Kârımız: maliyeti yazınca görünür'));
      expect(_resultText(tester), contains('Kalem toplamı: 11.500,00 TL'));

      await tester.enterText(formField('Bize maliyeti (birim)'), '1.000');
      await tester.pump();
      expect(
        _resultText(tester),
        'Müşteriye birim fiyat: 1.150,00 TL · Kârımız: 150,00 TL (%15)\n'
        'Kalem toplamı: 11.500,00 TL · Kârımız: 1.500,00 TL',
      );

      await tester.enterText(formField('Bize maliyeti (birim)'), '');
      await tester.pump();
      await tapButton(tester, 'Teklifi Oluştur');
      final item = _sentItem(adapter, '/offers/');
      expect(item['unit_price'], 1150);
      expect(item.containsKey('pricing_mode'), isFalse, reason: 'maliyetsiz kalem iç fiyatsızdır');
      expect(item.containsKey('internal_subcontract_cost'), isFalse);
    });

    testWidgets('satış fiyatını ben gireyim: maliyetle birlikte manual gider; zarar kırmızı ve açık yazılır', (tester) async {
      final adapter = await _openNew(tester);

      await tester.enterText(formField('Birim Fiyat'), '900');
      await tester.enterText(formField('Bize maliyeti (birim)'), '1.000');
      await tester.pump();
      expect(
        _resultText(tester),
        'Müşteriye birim fiyat: 900,00 TL · Zararımız: 100,00 TL (%10)\n'
        'Kalem toplamı: 9.000,00 TL · Zararımız: 1.000,00 TL',
      );

      await tapButton(tester, 'Teklifi Oluştur');
      final item = _sentItem(adapter, '/offers/');
      expect(item['unit_price'], 900);
      expect(item['pricing_mode'], 'manual');
      expect(item['internal_subcontract_cost'], 1000);
      expect(item['markup_percent'], isNull);
    });

    testWidgets('kâr oranıyla hesapla: fiyat alanı kilitli ve hesaplanan fiyatı gösterir; markup gider', (tester) async {
      final adapter = await _openNew(tester);
      await tester.enterText(formField('Birim Fiyat'), '500');
      await _pickMode(tester, 'Kâr oranıyla hesapla');

      expect(find.text('Maliyetin üstüne kâr yüzdesi eklenir'), findsOneWidget);
      final price = formField('Birim Fiyat (otomatik)');
      expect(price, findsOneWidget);
      expect(tester.widget<TextFormField>(price).enabled, isFalse);
      expect(_resultText(tester), contains('Müşteriye birim fiyat: — · maliyeti ve kâr oranını yazınca hesaplanır'));

      await tester.enterText(formField('Bize maliyeti (birim)'), '1.000');
      await tester.enterText(formField('Kâr oranı (%)'), '15');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.descendant(of: price, matching: find.byType(TextField))).controller!.text,
        '1150',
      );
      expect(
        _resultText(tester),
        'Müşteriye birim fiyat: 1.150,00 TL · Kârımız: 150,00 TL (%15)\n'
        'Kalem toplamı: 11.500,00 TL · Kârımız: 1.500,00 TL',
      );

      await tapButton(tester, 'Teklifi Oluştur');
      final item = _sentItem(adapter, '/offers/');
      expect(item['pricing_mode'], 'markup');
      expect(item['internal_subcontract_cost'], 1000);
      expect(item['markup_percent'], 15);
      expect(item['unit_price'], 1150);
    });

    testWidgets('sunucunun yuvarlaması: 1,15 + %50 = 1,73 (kayan nokta 1,72 bulurdu)', (tester) async {
      await _openNew(tester);
      await _pickMode(tester, 'Kâr oranıyla hesapla');
      await tester.enterText(formField('Bize maliyeti (birim)'), '1,15');
      await tester.enterText(formField('Kâr oranı (%)'), '50');
      await tester.pump();
      expect(_resultText(tester), startsWith('Müşteriye birim fiyat: 1,73 TL · Kârımız: 0,58 TL (%50,43)'));
      expect(_resultText(tester), contains('Kalem toplamı: 17,30 TL · Kârımız: 5,80 TL'));
    });

    testWidgets('kâr oranıyla hesapla: anlaşılır doğrulama, istek gitmez', (tester) async {
      final adapter = await _openNew(tester);
      await _pickMode(tester, 'Kâr oranıyla hesapla');

      await tapButton(tester, 'Teklifi Oluştur');
      expect(find.text('Maliyeti yaz; müşteri fiyatı bundan hesaplanır.'), findsOneWidget);
      expect(find.text('Kâr oranını yaz (ör. 20).'), findsOneWidget);

      await tester.enterText(formField('Bize maliyeti (birim)'), '1.000');
      await tester.enterText(formField('Kâr oranı (%)'), '-150');
      await tapButton(tester, 'Teklifi Oluştur');
      expect(find.text("Kâr oranı -%100'den küçük olamaz."), findsOneWidget);

      await tester.enterText(formField('Kâr oranı (%)'), '10000');
      await tapButton(tester, 'Teklifi Oluştur');
      expect(find.text('Kâr oranı en fazla %9.999,99 olabilir.'), findsOneWidget);

      await tester.enterText(formField('Bize maliyeti (birim)'), '-5');
      await tapButton(tester, 'Teklifi Oluştur');
      expect(find.text('Negatif değer girilemez.'), findsOneWidget);
      expect(adapter.calls, isNot(contains('/offers/')));
    });

    testWidgets('kullanma: maliyet ve sonuç gizlenir, iç alan gitmez', (tester) async {
      final adapter = await _openNew(tester);
      await tester.enterText(formField('Birim Fiyat'), '1.150');
      await tester.enterText(formField('Bize maliyeti (birim)'), '1.000');
      await _pickMode(tester, 'Kullanma');

      expect(find.text('Bu kalemde maliyet ve kâr tutulmaz'), findsOneWidget);
      expect(formField('Bize maliyeti (birim)'), findsNothing);
      expect(_result(), findsNothing);

      await tapButton(tester, 'Teklifi Oluştur');
      final item = _sentItem(adapter, '/offers/');
      expect(item.containsKey('pricing_mode'), isFalse);
      expect(item.containsKey('internal_subcontract_cost'), isFalse);
    });

    testWidgets('kayıtlı "kâr oranıyla" kalem: fiyat hesaplanmış görünür; elle girişe geçince fiyat yerinde kalır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1': [(status: 200, body: _offer(items: [_item()])), (status: 200, body: _offer(items: [_item()]))],
      });
      await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(offerId: 'o1'), user: _manager);

      expect(find.text('Kâr oranıyla hesapla').hitTestable(), findsOneWidget);
      expect(tester.widget<TextFormField>(formField('Birim Fiyat (otomatik)')).enabled, isFalse);
      expect(_resultText(tester), contains('Kârımız: 150,00 TL (%15)'));

      await _pickMode(tester, 'Satış fiyatını ben gireyim');
      final price = formField('Birim Fiyat');
      expect(tester.widget<TextFormField>(price).enabled, isTrue);
      expect(tester.widget<TextField>(find.descendant(of: price, matching: find.byType(TextField))).controller!.text, '1150');
      expect(formField('Kâr oranı (%)'), findsNothing);

      await tester.enterText(price, '1.200');
      await tester.pump();
      expect(_resultText(tester), startsWith('Müşteriye birim fiyat: 1.200,00 TL · Kârımız: 200,00 TL (%20)'));
      await tapButton(tester, 'Kaydet');
      final item = _sentItem(adapter, '/offers/o1');
      expect(item['pricing_mode'], 'manual');
      expect(item['unit_price'], 1200);
      expect(item['internal_subcontract_cost'], 1000);
    });

    testWidgets('360 dp ve büyük yazıda bölüm taşmaz', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final adapter = FakeHttpClientAdapter(script: {'/offers/o1': [(status: 200, body: _offer(items: [_item()]))]});
      await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(offerId: 'o1'), user: _manager);
      await tester.binding.setSurfaceSize(const Size(360, 1600));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_result(), findsOneWidget);
    });
  });

  group('detay ve revizyon', () {
    Future<void> pumpDetail(WidgetTester tester, Widget screen, Map<String, List<ScriptedResponse>> script,
        {Set<String>? permissions}) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = await buildFakeApiClient(FakeHttpClientAdapter(script: script));
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => screen)]);
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          authControllerProvider.overrideWith(
            () => FakeAuth(testUser(permissions ?? {'offers.read', kPermOffersInternalPricingRead})),
          ),
          offersTodayProvider.overrideWithValue(DateTime.utc(2026, 10, 11)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
    }

    Map<String, List<ScriptedResponse>> detailScript(List<Map<String, dynamic>> items) => {
          '/offers/o1': [(status: 200, body: _offer(items: items))],
          '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
          '/offers/o1/share-links': [(status: 200, body: {'share_links': <Object>[]})],
        };

    testWidgets('teklif detayı: bize maliyeti, kâr oranı, beklenen kâr (birim ve kalem)', (tester) async {
      await pumpDetail(tester, const OfferDetailScreen(offerId: 'o1'), detailScript([
        _item(),
        _item(id: 'i2', mode: 'manual', markup: null, price: 900, qty: 2),
      ]));

      expect(find.text('Maliyet ve Kâr'), findsNWidgets(2));
      expect(find.text('Bize maliyeti: 1.000,00 TL / m²'), findsNWidgets(2));
      expect(find.text('Kâr oranı: %15 · fiyat bundan hesaplandı'), findsOneWidget);
      expect(_line('Beklenen kâr: 150,00 TL / m² (%15) · bu kalemde 1.500,00 TL'), findsOneWidget);
      expect(find.text('Satış fiyatı elle girildi'), findsOneWidget);
      expect(_line('Beklenen zarar: 100,00 TL / m² (%10) · bu kalemde 200,00 TL'), findsOneWidget);
      for (final old in ['İç Fiyatlandırma', 'Mod: Markup', 'Mod: Manuel']) {
        expect(find.text(old), findsNothing, reason: old);
      }
      expect(find.textContaining('Efektif'), findsNothing);
      expect(find.textContaining('İç maliyet'), findsNothing);
    });

    testWidgets('iç fiyat okuma izni yoksa bölüm yok', (tester) async {
      await pumpDetail(tester, const OfferDetailScreen(offerId: 'o1'), detailScript([_item()]),
          permissions: {'offers.read'});
      expect(find.text('Maliyet ve Kâr'), findsNothing);
      expect(find.textContaining('Bize maliyeti'), findsNothing);
    });

    testWidgets('revizyon detayı aynı sözcükleri kullanır', (tester) async {
      await pumpDetail(tester, const OfferRevisionDetailScreen(offerId: 'o1', revisionId: 'r1'), {
        '/offers/o1/revisions/r1': [
          (
            status: 200,
            body: {
              ..._offer(items: [_item()]),
              'id': 'r1',
              'offer_id': 'o1',
              'revision_no': 1,
              'currency': 'TRY',
              'created_at': '2026-10-06T10:00:00Z',
            },
          ),
        ],
        '/offers/o1': [(status: 200, body: _offer())],
      });

      expect(find.text('Maliyet ve Kâr'), findsOneWidget);
      expect(find.text('Bize maliyeti: 1.000,00 TL / m²'), findsOneWidget);
      expect(find.text('Kâr oranı: %15 · fiyat bundan hesaplandı'), findsOneWidget);
      expect(_line('Beklenen kâr: 150,00 TL / m² (%15) · bu kalemde 1.500,00 TL'), findsOneWidget);
      expect(find.textContaining('İç maliyet'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

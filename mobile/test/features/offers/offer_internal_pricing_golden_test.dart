@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../products/products_fakes.dart' show loadAppFonts, productsTestTheme;
import '../projects/form_test_support.dart' show FakeAuth, testUser;

/// Teklif kaleminin "Maliyet ve Kâr" bölümü, küçük telefon (360x800):
/// formda "Kâr oranıyla hesapla" kalemi (kilitli otomatik fiyat, maliyet,
/// oran, canlı sonuç) ve teklif detayında kalem özetleri (kâr + zarar).
/// Üretmek:
///   flutter test --tags golden --update-goldens test/features/offers/offer_internal_pricing_golden_test.dart

final _manager = testUser({
  'offers.read',
  'offers.create',
  'offers.update',
  kPermOffersInternalPricingRead,
  kPermOffersInternalPricingManage,
});

Map<String, dynamic> _item(String id, String name, {required String mode, required num cost, required num price, num? markup, num qty = 10}) => {
      'id': id,
      'product_name': name,
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

final _offer = {
  'id': 'o1',
  'offer_no': 'TKF-2026-0042',
  'revision_no': 0,
  'customer_id': null,
  'customer_name': 'Moda Mimarlık',
  'offer_date': '2026-10-06',
  'valid_until': null,
  'subtotal': 13300,
  'vat_rate': 20,
  'vat_amount': 2660,
  'grand_total': 15960,
  'notes': '',
  'status': 'taslak',
  'is_passive': false,
  'items': [
    _item('i1', 'Seramik döşeme (60×60)', mode: 'markup', cost: 1000, price: 1150, markup: 15),
    _item('i2', 'Derz dolgusu', mode: 'manual', cost: 1000, price: 900, qty: 2),
  ],
};

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(360, 800) * 2.0;
  addTearDown(tester.view.reset);
  final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {
    '/offers/o1': [for (var i = 0; i < 3; i++) (status: 200, body: _offer)],
    '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
    '/offers/o1/share-links': [(status: 200, body: {'share_links': <Object>[]})],
  }));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => FakeAuth(_manager)),
      offersTodayProvider.overrideWithValue(DateTime.utc(2026, 10, 11)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: productsTestTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: screen,
    ),
  ));
  await tester.pumpAndSettle();
}

/// [target] kaydırılabilir alanın en üstüne (biraz boşlukla) gelir.
Future<void> _scrollToTop(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target));
  await tester.pumpAndSettle();
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 24));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  testWidgets('offer form markup item', (tester) async {
    await _pump(tester, const OfferCreateScreen(offerId: 'o1'));
    // İlk kalemin miktar satırı ekranın üstünde: kilitli otomatik fiyattan
    // canlı sonuca kadar bütün bölüm görünsün.
    await _scrollToTop(tester, find.widgetWithText(TextFormField, 'Miktar').first);

    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/offer_internal_pricing_form_360x800.png'));
  });

  testWidgets('offer detail item profit', (tester) async {
    await _pump(tester, const OfferDetailScreen(offerId: 'o1'));
    await _scrollToTop(tester, find.text('Seramik döşeme (60×60)'));

    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/offer_internal_pricing_detail_360x800.png'));
  });
}

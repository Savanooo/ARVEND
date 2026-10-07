@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/offers/presentation/product_suggestions.dart';
import 'package:arvend/features/products/data/products_providers.dart';

import '../../test_utils/fake_api_client.dart';
import '../products/products_fakes.dart';
import '../projects/form_test_support.dart' show formField;

/// Teklif kalemindeki katalog önerileri, küçük telefon (360x800, uygulama
/// fontları): "kutu" yazılmış, altı öneri + "daha fazla" satırı. Üretmek:
///   flutter test --tags golden --update-goldens test/features/offers
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  testWidgets('offer item catalog suggestions', (tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;

    final repo = FakeProductsRepository(catalog: [
      productJson(
        id: 'k1', name: 'Siyah Kutu Profil 40×40×2 mm', unit: 'boy', unitPrice: 512,
        category: 'Siyah Kutu Profil', source: 'demirprofil',
      ),
      productJson(
        id: 'k2', name: 'Galvaniz Kutu Profil 40×40×1,35 mm', unit: 'boy', unitPrice: 498.75,
        category: 'Galvaniz Kutu Profil', source: 'demirprofil',
      ),
      productJson(id: 'u1', name: 'Kutu Kapak Contası', unit: 'm', unitPrice: 42.5, category: 'YALITIM', source: 'ulas'),
      for (var i = 0; i < 6; i++)
        productJson(
          id: 'x$i', name: 'Kutu Profil ${20 + i * 10}×${20 + i * 10}×2 mm', unit: 'boy', unitPrice: 300.0 + i,
          category: 'Siyah Kutu Profil', source: 'demirprofil',
        ),
    ]);
    final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser({'offers.create', 'products.read'}))),
        productsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: productsTestTheme(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const OfferCreateScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    final name = formField('Ürün / Hizmet Adı');
    await tester.ensureVisible(name);
    await tester.pumpAndSettle();
    await tester.enterText(name, 'kutu');
    await tester.pump(kProductSuggestDebounce);
    await tester.pumpAndSettle();
    // Önce önerilerin altı, sonra alanın kendisi görünür olsun: alan
    // ekranın üstünde, öneriler hemen altında.
    await tester.ensureVisible(find.byKey(const ValueKey('offer-product-suggestions')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(name);
    await tester.pumpAndSettle();
    // Yüzen etiket uygulama çubuğunun altında kalmasın.
    await tester.drag(find.byType(ListView).first, const Offset(0, 24));
    await tester.pumpAndSettle();

    try {
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/offer_product_suggestions_360x800.png'));
    } finally {
      debugDisableShadows = true;
    }
  });
}

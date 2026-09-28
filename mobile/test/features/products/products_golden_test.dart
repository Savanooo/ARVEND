@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/products/products_routes.dart';

import 'products_fakes.dart';

/// Ürünler / Fiyat Kaynakları / Zam Geçmişi ekran görüntüleri (360x800,
/// uygulama fontlarıyla): liste, detay, form, kaynak kartları, kâr oranı
/// sayfası, zam geçmişi ve filtre sayfası -- sahip (tam yetki), salt-okunur
/// (yalnızca products.read) ve izinsiz varyantlarıyla. Uzun ekranların bir de
/// tam sayfa (`_360_full`) görüntüsü var. Üretmek:
///   flutter test --tags golden --update-goldens test/features/products
/// Veri deterministik (products_fakes.dart), saat sabit (kTestNow), ağ yok.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  Future<void> pumpAt(WidgetTester tester, String location, {User? user, FakeProductsRepository? repo}) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    // Gerçek gölgeler (flutter_test varsayılanı düz siyah blok); expectGolden
    // sonunda geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(
      productsHarness(user: user ?? ownerUser, repo: repo ?? FakeProductsRepository(), location: location),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    try {
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    } finally {
      // Test gövdesi bitmeden geri alınmalı (binding değişmezleri denetler).
      debugDisableShadows = true;
    }
  }

  /// Tüm kaydırma içeriği tek görüntüde: pencere, dikey listenin içerik
  /// yüksekliğine göre büyütülür. ListView henüz çizilmemiş çocukların
  /// yüksekliğini TAHMİN eder; bu yüzden ölçüm, pencere boyu değişmeyene
  /// kadar (tüm çocuklar çizilip gerçek yükseklik bulunana dek) tekrarlanır.
  Future<void> expectFullPage(WidgetTester tester, String name) async {
    for (var i = 0; i < 6; i++) {
      final scrollableFinder = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      final position = tester.state<ScrollableState>(scrollableFinder).position;
      final viewport = tester.renderObject<RenderViewportBase>(
        find.descendant(of: scrollableFinder, matching: find.byType(Viewport)).first,
      );
      var content = 0.0;
      viewport.visitChildren((child) => content += (child as RenderSliver).geometry?.scrollExtent ?? 0);
      final current = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final target = (current - position.viewportDimension + content).ceilToDouble().clamp(800.0, 20000.0);
      if ((target - current).abs() < 1) break;
      tester.view.physicalSize = Size(360, target) * 2.0;
      await tester.pumpAndSettle();
    }
    await expectGolden(tester, name);
  }

  // ---------- Ürünler listesi ----------

  testWidgets('list owner', (tester) async {
    await pumpAt(tester, ProductsPaths.list);
    await expectGolden(tester, 'products_list_owner_360x800');
  });

  testWidgets('list read-only', (tester) async {
    // Backend yanlışlıkla tedarikçi fiyatı döndürse bile görünmemeli.
    await pumpAt(tester, ProductsPaths.list, user: readOnlyUser, repo: FakeProductsRepository(manage: true));
    await expectGolden(tester, 'products_list_readonly_360x800');
  });

  testWidgets('list no access', (tester) async {
    await pumpAt(tester, ProductsPaths.list, user: noAccessUser);
    await expectGolden(tester, 'products_no_access_360x800');
  });

  // ---------- Ürün detayı ----------

  testWidgets('detail owner (Demir Profil)', (tester) async {
    await pumpAt(tester, ProductsPaths.detail('p1'));
    await expectGolden(tester, 'product_detail_owner_360x800');
  });

  testWidgets('detail owner full page', (tester) async {
    await pumpAt(tester, ProductsPaths.detail('p1'));
    await expectFullPage(tester, 'product_detail_owner_360_full');
  });

  testWidgets('detail read-only full page', (tester) async {
    await pumpAt(tester, ProductsPaths.detail('p1'), user: readOnlyUser, repo: FakeProductsRepository(manage: false));
    await expectFullPage(tester, 'product_detail_readonly_360_full');
  });

  testWidgets('detail manual product (read-only)', (tester) async {
    await pumpAt(tester, ProductsPaths.detail('p3'), user: readOnlyUser, repo: FakeProductsRepository(manage: false));
    await expectGolden(tester, 'product_detail_manual_readonly_360x800');
  });

  // ---------- Ürün formu ----------

  testWidgets('form new', (tester) async {
    await pumpAt(tester, ProductsPaths.create);
    await expectGolden(tester, 'product_form_new_owner_360x800');
  });

  testWidgets('form edit synced (linked) full page', (tester) async {
    await pumpAt(tester, ProductsPaths.edit('p1'));
    await expectFullPage(tester, 'product_form_edit_linked_owner_360_full');
  });

  testWidgets('form edit read-only (denied)', (tester) async {
    await pumpAt(tester, ProductsPaths.edit('p1'), user: readOnlyUser);
    await expectGolden(tester, 'product_form_edit_readonly_360x800');
  });

  // ---------- Fiyat Kaynakları ----------

  testWidgets('sources owner', (tester) async {
    await pumpAt(tester, ProductsPaths.sources);
    await expectGolden(tester, 'price_sources_owner_360x800');
  });

  testWidgets('sources owner full page', (tester) async {
    await pumpAt(tester, ProductsPaths.sources);
    await expectFullPage(tester, 'price_sources_owner_360_full');
  });

  testWidgets('sources read-only full page', (tester) async {
    await pumpAt(tester, ProductsPaths.sources, user: readOnlyUser, repo: FakeProductsRepository(manage: false));
    await expectFullPage(tester, 'price_sources_readonly_360_full');
  });

  testWidgets('markup settings sheet', (tester) async {
    await pumpAt(tester, ProductsPaths.sources);
    final button = find.text('Kâr oranı ayarları').first;
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Ulaş kâr oranı ayarları'), findsOneWidget);
    await expectGolden(tester, 'price_source_settings_owner_360x800');
  });

  // ---------- Zam Geçmişi ----------

  testWidgets('price changes owner', (tester) async {
    await pumpAt(tester, ProductsPaths.priceChanges);
    await expectGolden(tester, 'price_changes_owner_360x800');
  });

  testWidgets('price changes owner full page', (tester) async {
    await pumpAt(tester, ProductsPaths.priceChanges);
    await expectFullPage(tester, 'price_changes_owner_360_full');
  });

  testWidgets('price changes read-only full page', (tester) async {
    await pumpAt(tester, ProductsPaths.priceChanges, user: readOnlyUser, repo: FakeProductsRepository(manage: false));
    await expectFullPage(tester, 'price_changes_readonly_360_full');
  });

  testWidgets('price changes event selected full page', (tester) async {
    await pumpAt(tester, ProductsPaths.priceChanges);
    await tester.tap(find.text('21 Eylül 2026 00:05'));
    await tester.pumpAndSettle();
    await expectFullPage(tester, 'price_changes_event_owner_360_full');
  });

  testWidgets('price changes filter sheet', (tester) async {
    await pumpAt(tester, ProductsPaths.priceChanges);
    await tester.tap(find.text('Filtrele'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'price_changes_filters_360x800');
  });
}

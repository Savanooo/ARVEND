@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/cost_codes/cost_codes_routes.dart';

import 'cost_codes_test_support.dart';

/// Maliyet Kodları ekran görüntüleri (360x800, uygulama fontlarıyla):
/// liste / detay / form x sahip (tam yetki) ve salt-okunur. Üretmek:
///   flutter test --tags golden --update-goldens test/features/cost_codes
/// Veri deterministik (`kCostCodeFixtures`), ağ yok.
void main() {
  setUpAll(loadAppFonts);

  Future<void> pumpAt(WidgetTester tester, {required User user, String location = kCostCodesPath}) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    // Gerçek gölgeler (flutter_test varsayılanı düz siyah blok); expectGolden
    // sonunda geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(
      buildCostCodesApp(user: user, repo: FakeCostCodesRepository(), initialLocation: location, theme: goldenTheme()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  testWidgets('list owner', (tester) async {
    await pumpAt(tester, user: ccOwnerUser);
    await expectGolden(tester, 'cost_codes_list_owner_360x800');
  });

  testWidgets('list owner full page', (tester) async {
    await pumpAt(tester, user: ccOwnerUser);
    final scrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
    );
    final fullHeight = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
    tester.view.physicalSize = Size(360, fullHeight) * 2.0;
    await tester.pumpAndSettle();
    await expectGolden(tester, 'cost_codes_list_owner_360_full');
  });

  testWidgets('list read-only', (tester) async {
    await pumpAt(tester, user: ccReadOnlyUser);
    await expectGolden(tester, 'cost_codes_list_readonly_360x800');
  });

  testWidgets('list no access', (tester) async {
    await pumpAt(tester, user: ccNoAccessUser);
    await expectGolden(tester, 'cost_codes_list_no_access_360x800');
  });

  testWidgets('detail owner', (tester) async {
    await pumpAt(tester, user: ccOwnerUser, location: costCodeDetailPath('c5'));
    await expectGolden(tester, 'cost_code_detail_owner_360x800');
  });

  testWidgets('detail read-only', (tester) async {
    await pumpAt(tester, user: ccReadOnlyUser, location: costCodeDetailPath('c5'));
    await expectGolden(tester, 'cost_code_detail_readonly_360x800');
  });

  testWidgets('form create', (tester) async {
    await pumpAt(tester, user: ccOwnerUser);
    await tester.tap(find.text('Yeni Maliyet Kodu'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'cost_code_form_create_360x800');
  });

  testWidgets('form edit', (tester) async {
    // Listeden açılır: kategori çipleri listenin verisinden gelir.
    await pumpAt(tester, user: ccOwnerUser);
    await tester.tap(find.text('Hazır Beton'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Düzenle'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'cost_code_form_edit_360x800');
  });
}

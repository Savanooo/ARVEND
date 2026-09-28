@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/suppliers/suppliers_routes.dart';

import 'suppliers_test_support.dart';

/// Tedarikçi ekran görüntüleri (360x800, uygulama fontlarıyla):
/// liste / detay / form x sahip (tam yetki) ve salt-okunur. Üretmek:
///   flutter test --tags golden --update-goldens test/features/suppliers
/// Veri deterministik (`kSupplierFixtures`), ağ yok.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  Future<void> pumpAt(
    WidgetTester tester, {
    required User user,
    String location = kSuppliersPath,
    Size size = const Size(360, 800),
  }) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = size * 2.0;
    addTearDown(tester.view.reset);
    // flutter_test gölgeleri varsayılan olarak düz siyah bloklarla çizer;
    // ekran görüntüsü cihazdaki gibi olsun diye gerçek gölge. Test sonunda
    // (expectGolden) geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(
      buildSuppliersApp(user: user, repo: FakeSuppliersRepository(), initialLocation: location, theme: goldenTheme()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  testWidgets('list owner', (tester) async {
    await pumpAt(tester, user: ownerUser);
    await expectGolden(tester, 'suppliers_list_owner_360x800');
  });

  testWidgets('list read-only', (tester) async {
    await pumpAt(tester, user: readOnlyUser);
    await expectGolden(tester, 'suppliers_list_readonly_360x800');
  });

  testWidgets('list no access', (tester) async {
    await pumpAt(tester, user: noAccessUser);
    await expectGolden(tester, 'suppliers_list_no_access_360x800');
  });

  testWidgets('detail owner', (tester) async {
    await pumpAt(tester, user: ownerUser, location: supplierDetailPath('s1'));
    await expectGolden(tester, 'supplier_detail_owner_360x800');
  });

  testWidgets('detail owner full page', (tester) async {
    // İnceleme için tüm alanlar + aksiyonlar tek görüntüde.
    await pumpAt(tester, user: ownerUser, location: supplierDetailPath('s1'));
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final fullHeight = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
    tester.view.physicalSize = Size(360, fullHeight) * 2.0;
    await tester.pumpAndSettle();
    await expectGolden(tester, 'supplier_detail_owner_360_full');
  });

  testWidgets('detail read-only', (tester) async {
    await pumpAt(tester, user: readOnlyUser, location: supplierDetailPath('s2'));
    await expectGolden(tester, 'supplier_detail_readonly_360x800');
  });

  testWidgets('form create', (tester) async {
    await pumpAt(tester, user: ownerUser);
    await tester.tap(find.text('Yeni Tedarikçi'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'supplier_form_create_360x800');
  });

  testWidgets('form edit', (tester) async {
    await pumpAt(tester, user: ownerUser, location: supplierDetailPath('s1'));
    await tester.tap(find.byTooltip('Düzenle'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'supplier_form_edit_360x800');
  });
}

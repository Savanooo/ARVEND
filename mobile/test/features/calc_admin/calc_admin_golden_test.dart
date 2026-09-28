@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/calc_admin/presentation/recipe_item_form_screen.dart';

import 'calc_admin_fakes.dart';

/// Metraj reçeteleri ekran görüntüleri (360x800, PNG 720x1600). Üretmek:
///   flutter test --tags golden --update-goldens test/features/calc_admin
/// Uygulama fontları yüklenir (Inter + MaterialIcons); veri tamamen sahte
/// depodan gelir, ağ yok.
const _base = '/diger/metraj-receteleri';

void _setView(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(360, 800) * 2.0;
  addTearDown(tester.view.reset);
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  final routeCases = <String, ({User user, String location})>{
    'calc_groups_owner_360x800': (user: ownerUser, location: _base),
    'calc_groups_readonly_360x800': (user: calcReaderUser, location: _base),
    'calc_group_detail_owner_360x800': (user: ownerUser, location: '$_base/g1'),
    'calc_group_detail_readonly_360x800': (user: calcReaderUser, location: '$_base/g1'),
    'calc_category_detail_owner_360x800': (user: ownerUser, location: '$_base/g1/c1'),
    'calc_category_detail_readonly_360x800': (user: calcReaderUser, location: '$_base/g1/c1'),
    'calc_no_access_360x800': (user: noCalcUser, location: _base),
  };

  for (final entry in routeCases.entries) {
    testWidgets(entry.key, (tester) async {
      _setView(tester);
      await withRealShadows(() async {
        await tester.pumpWidget(
          calcAdminApp(user: entry.value.user, repo: FakeCalcAdminRepository(), location: entry.value.location),
        );
        await tester.pumpAndSettle();
        await _expectGolden(tester, entry.key);
      });
    });
  }

  testWidgets('calc_group_form_owner_360x800', (tester) async {
    _setView(tester);
    await withRealShadows(() async {
      await tester.pumpWidget(calcAdminApp(user: ownerUser, repo: FakeCalcAdminRepository()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yeni Grup'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Ad *'), 'Kartonpiyer Sistemleri');
      await tester.pumpAndSettle();
      await _expectGolden(tester, 'calc_group_form_owner_360x800');
    });
  });

  for (final readOnly in [false, true]) {
    final name = 'calc_recipe_item_form_${readOnly ? 'readonly' : 'owner'}_360x800';
    testWidgets(name, (tester) async {
      _setView(tester);
      await withRealShadows(() async {
        final repo = FakeCalcAdminRepository();
        await tester.pumpWidget(calcAdminScreen(
          user: readOnly ? calcReaderUser : ownerUser,
          repo: repo,
          child: RecipeItemFormScreen(categoryId: 'c1', existing: repo.itemsData['c1']!.first),
        ));
        await tester.pumpAndSettle();
        await _expectGolden(tester, name);
      });
    });
  }

  testWidgets('calc_recipe_item_form_new_360x800', (tester) async {
    _setView(tester);
    await withRealShadows(() async {
      await tester.pumpWidget(calcAdminScreen(
        user: ownerUser,
        repo: FakeCalcAdminRepository(),
        fullscreenDialog: true,
        child: const RecipeItemFormScreen(categoryId: 'c1'),
      ));
      await tester.pumpAndSettle();
      await _expectGolden(tester, 'calc_recipe_item_form_new_360x800');
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/calc_admin/calc_admin_routes.dart';
import 'package:arvend/features/calc_admin/domain/calc_admin.dart';
import 'package:arvend/features/calc_admin/presentation/recipe_item_form_screen.dart';

import 'calc_admin_fakes.dart';

/// Davranış testleri uzun bir pencerede çizilir ki tembel (lazy) listelerin
/// tüm satırları ağaçta olsun; ekran boyutu golden testlerinde sınanır.
Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(400, 2400) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('permissions', () {
    testWidgets('no calculations.read: clear message, nothing fetched', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: noCalcUser, repo: repo));
      expect(find.textContaining('Metraj reçetelerini görüntüleme yetkin yok'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('fail-closed: user with an empty permission set sees nothing', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: calcUser(role: UserRole.admin, permissions: const []), repo: repo));
      expect(find.textContaining('yetkin yok'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('403 from the API shows an access message instead of crashing', (tester) async {
      final repo = FakeCalcAdminRepository()..groupsError = kForbidden;
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo));
      expect(find.textContaining('Metraj reçetelerini görüntüleme yetkin yok'), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('read-only: no create button, read-only notice, no product catalog fetch', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: calcReaderUser, repo: repo));
      expect(find.text('Petek Tavanlar'), findsOneWidget);
      expect(find.text('Yeni Grup'), findsNothing);
      expect(find.textContaining('yalnızca görüntüleyebilirsin'), findsOneWidget);

      await tester.tap(find.text('Petek Tavanlar'));
      await tester.pumpAndSettle();
      expect(find.text('Grup Bilgileri'), findsOneWidget);
      expect(find.text('Düzenle'), findsNothing);
      expect(find.text('Yeni Kategori'), findsNothing);

      await tester.tap(find.text('10x10 Petek Tavan'));
      await tester.pumpAndSettle();
      expect(find.text('Yeni Kalem'), findsNothing);
      expect(find.text('Ürün: Bağlı'), findsNWidgets(3));
      expect(find.text('Ürün: Bağlı değil'), findsOneWidget);
      expect(repo.calls, isNot(contains('products')));
      // Satır menüsü (Düzenle/Sil) yok; dokununca salt okunur form açılır.
      expect(find.byIcon(Icons.more_vert), findsNothing);
      await tester.tap(find.text('Petek Panel 10x10'));
      await tester.pumpAndSettle();
      expect(find.text('Reçete Kalemi'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.textContaining('Ürün bağlantısı: bağlı.'), findsOneWidget);
    });
  });

  group('owner flows', () {
    testWidgets('list -> group -> category shows linked product names', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo));
      expect(find.text('Yeni Grup'), findsOneWidget);
      await tester.tap(find.text('Petek Tavanlar'));
      await tester.pumpAndSettle();
      expect(find.text('Hesaplama Türleri (2)'), findsOneWidget);
      await tester.tap(find.text('10x10 Petek Tavan'));
      await tester.pumpAndSettle();
      expect(find.text('Malzeme Reçetesi (4)'), findsOneWidget);
      expect(find.text('Ürün: Alüminyum Petek Panel 10x10'), findsOneWidget);
      expect(find.text('Ürün: Bağlı ürün (listede yok)'), findsOneWidget);
      expect(repo.calls, contains('products'));
    });

    testWidgets('create group: slug follows the name, repo receives it', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo));
      await tester.tap(find.text('Yeni Grup'));
      await tester.pumpAndSettle();
      expect(find.text('Yeni Hesaplama Grubu'), findsOneWidget);

      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('Ad zorunludur'), findsOneWidget);
      expect(repo.createdGroups, isEmpty);

      await tester.enterText(find.widgetWithText(TextFormField, 'Ad *'), 'İç Cephe Işıklığı');
      await tester.pump();
      final slugField = tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Slug *'));
      expect(slugField.controller!.text, 'ic-cephe-isikligi');
      await tester.tap(find.text('Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.createdGroups.single.slug, 'ic-cephe-isikligi');
      expect(find.text('İç Cephe Işıklığı'), findsOneWidget);
    });

    testWidgets('write 403 is shown inside the form, sheet stays open', (tester) async {
      final repo = FakeCalcAdminRepository()..writeError = kForbidden;
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo, location: '$_base/g1'));
      // "Düzenle" diğer detay ekranlarındaki gibi üst çubukta.
      await tester.tap(find.byTooltip('Düzenle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bu işlem için yetkin yok'), findsOneWidget);
      expect(find.text('Grubu Düzenle'), findsOneWidget);
    });

    testWidgets('delete recipe item asks for confirmation first', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo, location: '$_base/g1/c1'));
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil'));
      await tester.pumpAndSettle();
      expect(find.text('Reçete Kalemini Sil'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.deletedItemIds, isEmpty);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      await tester.pumpAndSettle();
      expect(repo.deletedItemIds, ['i1']);
      expect(find.text('Malzeme Reçetesi (3)'), findsOneWidget);
    });

    testWidgets('manager without products.read keeps the existing product link on save', (tester) async {
      final repo = FakeCalcAdminRepository();
      final item = repo.itemsData['c1']!.first;
      await _pump(
        tester,
        calcAdminScreen(
          user: calcManagerNoProductsUser,
          repo: repo,
          child: RecipeItemFormScreen(categoryId: 'c1', existing: item),
        ),
      );
      expect(find.textContaining('kaydederken mevcut bağlantı korunur'), findsOneWidget);
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.itemInputs.single.id, 'i1');
      expect(repo.itemInputs.single.input.productId, 'p1');
      expect(repo.calls, isNot(contains('products')));
    });

    testWidgets('new recipe item: validation and comma decimals', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(
        tester,
        calcAdminScreen(user: ownerUser, repo: repo, child: const RecipeItemFormScreen(categoryId: 'c1')),
      );
      expect(find.text('Yeni Reçete Kalemi'), findsOneWidget);
      // Yeni kalemde Aktif anahtarı yok (web ile aynı).
      expect(find.text('Aktif'), findsNothing);

      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Malzeme adı zorunludur'), findsOneWidget);
      expect(find.text('Birim zorunludur'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Malzeme Adı *'), 'Alçı');
      await tester.enterText(find.widgetWithText(TextFormField, 'Birim *'), 'torba');
      await tester.enterText(find.widgetWithText(TextFormField, 'Katsayı / m²'), '0,35');
      await tester.enterText(find.widgetWithText(TextFormField, 'Fire (%)'), '-2');
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Fire (%) negatif olamaz'), findsOneWidget);
      expect(repo.itemInputs, isEmpty);

      await tester.enterText(find.widgetWithText(TextFormField, 'Fire (%)'), '2,5');
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final json = repo.itemInputs.single.input.toJson();
      expect(json['quantity_per_m2'], '0.35');
      expect(json['waste_percent'], '2.5');
      expect(json['product_id'], isNull);
      expect(json['calculation_type'], CalcType.areaBased);
    });

    testWidgets('product picker links a product (owner)', (tester) async {
      final repo = FakeCalcAdminRepository();
      final item = repo.itemsData['c1']![2]; // Askı Teli, bağlı değil
      await _pump(
        tester,
        calcAdminScreen(user: ownerUser, repo: repo, child: RecipeItemFormScreen(categoryId: 'c1', existing: item)),
      );
      final productField = find.text('Bağlı değil');
      await tester.ensureVisible(productField);
      await tester.tap(productField);
      await tester.pumpAndSettle();
      expect(find.text('Ürün Seç'), findsOneWidget);
      // Büyük harf + noktasız I: Türkçe duyarlı arama yine bulmalı.
      await tester.enterText(find.widgetWithText(TextField, 'Ürün adına göre ara'), 'ASKI');
      await tester.pumpAndSettle();
      expect(find.text('L Kenar Profili 3m'), findsNothing);
      await tester.tap(find.text('Askı Teli Paketi'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Askı Teli Paketi (paket'), findsOneWidget);
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.itemInputs.single.input.productId, 'p3');
    });
  });

  test('routes and menu descriptor are exposed for the integration step', () {
    expect(calcAdminMenuEntries.single.route, '/diger/metraj-receteleri');
    expect(calcAdminMenuEntries.single.permission, 'calculations.read');
    expect(calcAdminRoutes, hasLength(1));
  });
}

const _base = '/diger/metraj-receteleri';

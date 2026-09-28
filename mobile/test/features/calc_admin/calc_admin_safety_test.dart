import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/core/widgets/status_badge.dart';
import 'package:arvend/features/calc_admin/domain/calc_admin.dart';
import 'package:arvend/features/calc_admin/presentation/recipe_item_form_screen.dart';

import 'calc_admin_fakes.dart';

/// Türkçe sayı yazımı (belirsiz "1.250" reddi, sınırlar, gösterim), liste
/// sadeliği, silme/kayıt sırasındaki kilitler ve bekleyen yenileme.
const _base = '/diger/metraj-receteleri';

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(400, 2400) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('Türkçe ondalık girişi', () {
    test('virgül ondalık; virgülle birlikte noktalar binlik', () {
      expect(parseCalcDecimal('1,05').value, '1.05');
      expect(parseCalcDecimal('1.250,50').value, '1250.50');
      expect(parseCalcDecimal('12.500.000,5').value, '12500000.5');
      expect(parseCalcDecimal(' 3,6 ').value, '3.6');
      expect(parseCalcDecimal('').value, isNull);
      expect(parseCalcDecimal('').error, isNull);
    });

    test('virgülsüz nokta ondalık; binlik gibi görünen yazım BELİRSİZ ve reddedilir', () {
      expect(parseCalcDecimal('1.05').value, '1.05');
      expect(parseCalcDecimal('0.125').value, '0.125');
      expect(parseCalcDecimal('1250').value, '1250');
      expect(parseCalcDecimal('1.250').error, CalcDecimalError.ambiguous);
      expect(parseCalcDecimal('12.500').error, CalcDecimalError.ambiguous);
      expect(parseCalcDecimal('1.250.000').error, CalcDecimalError.ambiguous);
      expect(parseCalcDecimal('1.2.3').error, CalcDecimalError.invalid);
      expect(parseCalcDecimal('12.50,5').error, CalcDecimalError.invalid);
      expect(parseCalcDecimal('-2').error, CalcDecimalError.negative);
      // Kaydedilen gövde asla belirsiz değer taşımaz.
      expect(normalizeDecimal('1.250'), isNull);
    });

    test('doğrulama mesajları ve sütun sınırları', () {
      expect(
        validateDecimalField('1.250', label: 'Referans Fiyat (TL)'),
        'Referans Fiyat (TL) belirsiz: ondalık için virgül kullan (ör. 1,25), binlik ayırıcı yazma (ör. 1250)',
      );
      expect(validateDecimalField('1.250,50', label: 'Referans Fiyat (TL)', maxDecimals: 2), isNull);
      expect(
        validateDecimalField('1,255', label: 'Referans Fiyat (TL)', maxDecimals: 2),
        'Referans Fiyat (TL) en fazla 2 ondalık basamak olabilir',
      );
      expect(
        validateDecimalField('1000', label: 'Fire (%)', max: CalcLimits.wastePercent),
        'Fire (%) en fazla 999,99 olabilir',
      );
      expect(validateDecimalField('999,99', label: 'Fire (%)', max: CalcLimits.wastePercent), isNull);
      expect(validateDecimalField('abc', label: 'Fire (%)'), 'Fire (%) geçerli bir sayı olmalı');
      expect(validateDecimalField('-1', label: 'Fire (%)'), 'Fire (%) negatif olamaz');
    });

    test('gösterim ve form başlangıç değeri Türkçe', () {
      expect(formatCalcNumber('1.050000'), '1,05');
      expect(formatCalcNumber('0.250000'), '0,25');
      expect(formatCalcNumber('1250.000000'), '1.250');
      expect(formatCalcNumber('5'), '5');
      expect(formatCalcInput('1.050000'), '1,05');
      expect(formatCalcInput('1250.000000'), '1250');
      expect(formatCalcInput(null, fallback: '0'), '0');
      expect(formatCalcPriceInput('185.50'), '185,50');
      expect(formatCalcPriceInput('1250.00'), '1250');
    });
  });

  group('ekranlar', () {
    testWidgets('grup listesi: bilgi taşımayan "Aktif" rozeti ve slug yok, açıklama var', (tester) async {
      await _pump(tester, calcAdminApp(user: ownerUser, repo: FakeCalcAdminRepository()));
      expect(find.byType(StatusBadge), findsNothing);
      expect(find.textContaining('petek-tavanlar'), findsNothing);
      expect(find.textContaining('Sıra '), findsNothing);
      expect(find.text('Alüminyum petek ve karo tavan sistemleri'), findsOneWidget);
    });

    testWidgets('grup detayı: Düzenle üst çubukta; kategori satırında rozet/slug yok', (tester) async {
      await _pump(tester, calcAdminApp(user: ownerUser, repo: FakeCalcAdminRepository(), location: '$_base/g1'));
      expect(find.byTooltip('Düzenle'), findsOneWidget);
      expect(find.text('Standart 10x10 cm hücreli petek tavan'), findsOneWidget);
      // Tek "Aktif" rozeti detay kartındaki durum satırı.
      expect(find.widgetWithText(StatusBadge, 'Aktif'), findsOneWidget);
    });

    testWidgets('salt-okunur grup detayında Düzenle yok, ortak açıklama var', (tester) async {
      await _pump(tester, calcAdminApp(user: calcReaderUser, repo: FakeCalcAdminRepository(), location: '$_base/g1'));
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.byType(ReadOnlyNotice), findsOneWidget);
    });

    testWidgets('reçete kartı: Türkçe katsayı, yuvarlama kendi satırında', (tester) async {
      await _pump(tester, calcAdminApp(user: ownerUser, repo: FakeCalcAdminRepository(), location: '$_base/g1/c1'));
      expect(find.text('Katsayı 1,05 · Fire %3'), findsOneWidget);
      expect(find.text('Katsayı 0,25 · Fire %0'), findsOneWidget);
      expect(find.text('Yuvarlama: Yukarı yuvarla (tam sayı/paket)'), findsNWidgets(2));
      expect(find.textContaining('1.05'), findsNothing);
    });

    testWidgets('kalem formu Türkçe açılır; "1.250" referans fiyatı kaydedilmez', (tester) async {
      final repo = FakeCalcAdminRepository();
      final item = repo.itemsData['c1']![1];
      await _pump(
        tester,
        calcAdminScreen(user: ownerUser, repo: repo, child: RecipeItemFormScreen(categoryId: 'c1', existing: item)),
      );
      String text(String label) =>
          tester.widget<TextFormField>(find.widgetWithText(TextFormField, label)).controller!.text;
      expect(text('Katsayı / m (çevre)'), '1,05');
      expect(text('Referans Fiyat (TL)'), '185,50');

      await tester.enterText(find.widgetWithText(TextFormField, 'Referans Fiyat (TL)'), '1.250');
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Referans Fiyat (TL) belirsiz'), findsOneWidget);
      expect(repo.calls.where((c) => c.startsWith('updateItem')), isEmpty);

      await tester.enterText(find.widgetWithText(TextFormField, 'Referans Fiyat (TL)'), '1.250,50');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('updateItem')), isNotEmpty);
      expect(repo.itemInputs.last.input.toJson()['reference_unit_price'], '1250.50');
    });

    testWidgets('silme sürerken Kaydet ve Sil kilitli; sayfa kapatılamaz', (tester) async {
      final gate = Completer<void>();
      final repo = FakeCalcAdminRepository()..writeGate = gate;
      final item = repo.itemsData['c1']!.first;
      await _pump(
        tester,
        calcAdminScreen(user: ownerUser, repo: repo, child: RecipeItemFormScreen(categoryId: 'c1', existing: item)),
      );
      await tester.tap(find.byTooltip('Sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      await tester.pump();

      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline)).onPressed, isNull);
      expect(tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Kaydet')).onPressed, isNull);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(RecipeItemFormScreen), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.deletedItemIds, [item.id]);
      expect(find.byType(RecipeItemFormScreen), findsNothing);
      expect(repo.calls.where((c) => c.startsWith('deleteItem')).length, 1);
    });

    testWidgets('listeden aynı kalem silinirken ikinci silme isteği atılmaz', (tester) async {
      final gate = Completer<void>();
      final repo = FakeCalcAdminRepository()..writeGate = gate;
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo, location: '$_base/g1/c1'));
      Future<void> deleteFirst() async {
        await tester.tap(find.byIcon(Icons.more_vert).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sil'));
        await tester.pumpAndSettle();
      }

      await deleteFirst();
      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      await tester.pump();
      // İstek sürerken aynı kaleme ikinci kez: onay bile açılmaz.
      await deleteFirst();
      expect(find.text('Reçete Kalemini Sil'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('deleteItem')).length, 1);
      expect(find.text('Malzeme Reçetesi (3)'), findsOneWidget);
    });

    testWidgets('grup formu: kayıt sürerken kapatılamaz; liste formun kapanmasına bağlı olmadan tazelenir', (
      tester,
    ) async {
      final gate = Completer<void>();
      final repo = FakeCalcAdminRepository()..writeGate = gate;
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo));
      await tester.tap(find.text('Yeni Grup'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Ad *'), 'Kartonpiyer');
      await tester.tap(find.text('Oluştur'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Yeni Hesaplama Grubu'), findsOneWidget);

      final before = repo.calls.where((c) => c == 'groups').length;
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Yeni Hesaplama Grubu'), findsNothing);
      expect(repo.calls.where((c) => c == 'groups').length, greaterThan(before));
    });

    testWidgets('aşağı çekip yenileme veri gelene kadar sürer', (tester) async {
      final repo = FakeCalcAdminRepository();
      await _pump(tester, calcAdminApp(user: ownerUser, repo: repo));
      final gate = Completer<void>();
      repo.groupsGate = gate;
      final before = repo.calls.where((c) => c == 'groups').length;
      // Uzun test penceresinde (2400 px) gösterge ekranın dörtte birinden sonra kurulur.
      await tester.drag(find.textContaining('Teklif oluştururken'), const Offset(0, 900));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(repo.calls.where((c) => c == 'groups').length, greaterThan(before));
      // İstek bitmeden gösterge kapanmadı; eski liste de ekranda.
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      expect(find.text('Petek Tavanlar'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });
  });
}

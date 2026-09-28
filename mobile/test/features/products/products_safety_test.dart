import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/products/data/products_providers.dart';
import 'package:arvend/features/products/domain/price_format.dart';
import 'package:arvend/features/products/domain/product.dart';
import 'package:arvend/features/products/presentation/widgets/products_common.dart';
import 'package:arvend/features/products/products_routes.dart';

import 'products_fakes.dart';

/// Sayfalamanın çevrimdışı davranışı, dar ekran tarih biçimi, fiyat/alan
/// sınırları ve salt-okunur liste açıklaması.
void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('daha fazla yükle', () {
    test('hata sonrası kaydırma (otomatik) yeniden denemez; yalnızca "Tekrar Dene" dener', () async {
      final catalog = [for (var i = 0; i < 150; i++) productJson(id: 'x$i', name: 'Ürün $i')];
      final repo = FakeProductsRepository(catalog: catalog);
      final container = ProviderContainer(overrides: [productsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final sub = container.listen(productListProvider(''), (_, _) {});
      addTearDown(sub.close);
      await container.read(productListProvider('').future);
      expect(repo.listCalls.length, 1);

      repo.listError = mapHttpError(null, null);
      final notifier = container.read(productListProvider('').notifier);
      await notifier.loadMore(auto: true);
      expect(repo.listCalls.length, 2);
      expect(container.read(productListProvider('')).requireValue.loadMoreError, isNotNull);

      // Çevrimdışıyken her kaydırma bildirimi yeni istek atmaz, hata kalır.
      for (var i = 0; i < 5; i++) {
        await notifier.loadMore(auto: true);
      }
      expect(repo.listCalls.length, 2);
      expect(container.read(productListProvider('')).requireValue.loadMoreError, isNotNull);

      // "Tekrar Dene" (otomatik değil) yeniden dener.
      repo.listError = null;
      await notifier.loadMore();
      expect(repo.listCalls.length, 3);
      final page = container.read(productListProvider('')).requireValue;
      expect(page.loadMoreError, isNull);
      expect(page.items.length, 150);
    });
  });

  test('dönem aralığı: tarih parçaları bölünmez, satır yalnızca tarihler arasından kırılır', () {
    expect(formatDayRangeNoBreak('2026-08-30', '2026-09-28'), '30 Ağustos 2026 – 28 Eylül 2026');
    expect(formatDayRangeNoBreak('2026-09-28', '2026-09-28'), '28 Eylül 2026');
  });

  test('fiyat üst sınırı Türkçe mesajla durur (sunucunun ham taşma hatası yerine)', () {
    expect(parsePriceInput('999999999999,99').value, 999999999999.99);
    expect(parsePriceInput('1000000000000').error, 'Fiyat en fazla 999.999.999.999,99 TL olabilir.');
  });

  group('ekranlar', () {
    Future<FakeProductsRepository> pump(WidgetTester tester, String location, {bool readOnly = false}) async {
      final repo = FakeProductsRepository();
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(productsHarness(user: readOnly ? readOnlyUser : ownerUser, repo: repo, location: location));
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('salt-okunur liste neden ekleme olmadığını söyler', (tester) async {
      await pump(tester, ProductsPaths.list, readOnly: true);
      expect(find.byType(ReadOnlyNotice), findsOneWidget);
      expect(find.text(kProductsListReadOnly), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('yönetici listede açıklama görmez', (tester) async {
      await pump(tester, ProductsPaths.list);
      expect(find.byType(ReadOnlyNotice), findsNothing);
    });

    testWidgets('ürün formu uzunlukları veritabanı sütunlarıyla sınırlı', (tester) async {
      final repo = await pump(tester, ProductsPaths.create);
      Finder field(String label) => find.widgetWithText(TextFormField, label);
      await tester.enterText(field('Ürün Adı *'), 'Ç' * 250);
      await tester.enterText(field('Birim *'), 'metre kare (1,20 m genişlik rulo)');
      await tester.enterText(field('Kategori'), 'K' * 120);
      await tester.pump();
      String text(String label) => tester.widget<TextFormField>(field(label)).controller!.text;
      expect(text('Ürün Adı *').length, ProductFieldLimits.name);
      expect(text('Birim *').length, ProductFieldLimits.unit);
      expect(text('Kategori').length, ProductFieldLimits.category);
      expect(repo.created, isEmpty);
    });
  });
}

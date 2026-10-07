import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/calculations/domain/calc.dart';
import 'package:arvend/features/calculations/presentation/metraj_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Metraj sonucunda ürün fiyatı olmayan satırlar: sunucu reçetenin referans
/// fiyatını kullanır ya da 0 TL bırakır ve satırı `price_source`/
/// `price_warning` ile işaretler. Ekran her satırı işaretler, tek bir özet
/// not gösterir ve aynı satırlar için tekrar eden uyarı kutularını atar.

Map<String, dynamic> _item(String id, String name, String price, String total,
        {String source = 'product', String? warning, String? productId = 'p1'}) =>
    {
      'recipe_item_id': id, 'material_name': name, 'unit': 'adet', 'quantity': '2',
      'product_id': productId, 'unit_price': price, 'line_total': total, 'group_name': '',
      'calculation_type': 'fixed', 'factor': '2', 'waste_percent': '0', 'rounding_type': 'none',
      'price_source': source, 'price_warning': ?warning,
    };

Map<String, dynamic> _runJson() => {
      'category': {'id': 'cat1', 'slug': 'tavan', 'name': 'Tavan'},
      'input': {'footprint_area': '10', 'effective_area': '10', 'perimeter': null},
      'items': [
        _item('r1', 'Fiyatlı', '50.00', '100.00'),
        _item('r2', 'Referanslı', '30.00', '60.00', source: 'reference', warning: 'referans fiyat kullanıldı'),
        _item('r3', 'Fiyatsız', '0.00', '0.00', source: 'none', warning: 'fiyat yok', productId: null),
      ],
      'total_cost': '160.00',
      'warnings': [
        {'item_id': 'r2', 'code': 'product_zero_price', 'message': '"Referanslı" için ürün fiyatı 0 TL; ...'},
        {'item_id': 'r3', 'code': 'product_missing', 'message': '"Fiyatsız" bir ürüne bağlı değil; ...'},
        {'item_id': 'r9', 'code': 'perimeter_missing', 'message': 'Çevre bilinmiyor'},
      ],
    };

void main() {
  group('model', () {
    test('price_source/price_warning okunur; eski sunucuda boş', () {
      final result = CalcRunResult.fromJson(_runJson());
      expect(result.items[0].priceSource, 'product');
      expect(result.items[0].hasPriceWarning, isFalse);
      expect(result.items[1].priceWarning, 'referans fiyat kullanıldı');
      expect(result.items[2].priceSource, CalcResultItem.priceSourceNone);

      final old = _item('r1', 'Eski', '1', '2')
        ..remove('price_source')
        ..remove('price_warning');
      final parsed = CalcResultItem.fromJson(old);
      expect(parsed.priceSource, '');
      expect(parsed.hasPriceWarning, isFalse);
    });

    test('özet: referans ve fiyatsız satırları sayar; uyarı yoksa null', () {
      final result = CalcRunResult.fromJson(_runJson());
      final summary = calcPriceSummary(result.items)!;
      expect(summary, contains('1 kalemde ürün fiyatı olmadığından reçetedeki referans fiyat kullanıldı'));
      expect(summary, contains('1 kalemin fiyatı yok (0 TL hesaplandı)'));
      expect(calcPriceSummary([result.items.first]), isNull);
    });

    test('satırda işaretlenen fiyat uyarıları listeden çıkar, diğerleri kalır', () {
      final result = CalcRunResult.fromJson(_runJson());
      expect(nonPriceWarnings(result).map((w) => w.code), ['perimeter_missing']);
    });

    test('teklife aktarımda fiyat kaynağı snapshot\'a yazılır', () {
      final result = CalcRunResult.fromJson(_runJson());
      final items = buildOfferItemsFromCalcResult(result, {'r2'});
      final snapshot = items.single.calcSnapshot as Map<String, dynamic>;
      expect(snapshot['price_source'], 'reference');
      expect(items.single.unitPrice, 30);
    });
  });

  testWidgets('satırlar işaretlenir, tek özet not gösterilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [
        (
          status: 200,
          body: {
            'groups': [
              {
                'id': 'g1', 'slug': 'tavanlar', 'name': 'Tavanlar',
                'categories': [
                  {'id': 'cat1', 'group_id': 'g1', 'slug': 'tavan', 'name': 'Tavan', 'description': ''},
                ],
              },
            ],
          },
        ),
      ],
      '/calculations/run': [(status: 200, body: _runJson())],
    });
    final client = await buildFakeApiClient(adapter);
    await tester.binding.setSurfaceSize(const Size(500, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser({'calculations.read', 'offers.create'}))),
      ],
      child: const MaterialApp(home: MetrajScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<CalcGroupWithCategories>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tavanlar').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tavan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '10');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('metraj-price-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('metraj-price-warning-r1')), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('metraj-price-warning-r2')), matching: find.text('Referans fiyat kullanıldı')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('metraj-price-warning-r3')), matching: find.text('Fiyat yok')),
        findsOneWidget);
    // Satırda işaretli fiyat uyarıları ayrı kutu olarak tekrar etmez.
    expect(find.textContaining('bir ürüne bağlı değil'), findsNothing);
    expect(find.text('Çevre bilinmiyor'), findsOneWidget);
  });
}

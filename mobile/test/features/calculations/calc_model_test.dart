import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/features/calculations/domain/calc.dart';

void main() {
  group('CalcRunResult.fromJson', () {
    test('backend calculations/run yanıtındaki tüm sayısal alanlar String olarak parse edilir', () {
      final json = {
        'category': {'id': 'c1', 'slug': 'petek-tavan-10x10', 'name': '10x10 Petek Tavan'},
        'input': {'footprint_area': '20', 'effective_area': '20', 'perimeter': '18'},
        'items': [
          {
            'recipe_item_id': 'r1',
            'material_name': 'Petek Panel',
            'unit': 'm2',
            'quantity': '100.000000',
            'product_id': 'p1',
            'unit_price': '230.00',
            'line_total': '23000.00',
            'group_name': 'Panel',
            'calculation_type': 'area_based',
            'factor': '5',
            'waste_percent': '0',
            'rounding_type': 'none',
          },
        ],
        'total_cost': '43100.00',
        'warnings': [
          {'item_id': 'r2', 'code': 'product_missing', 'message': 'ürün yok'},
        ],
      };

      final result = CalcRunResult.fromJson(json);

      expect(result.categoryId, 'c1');
      expect(result.effectiveArea, '20');
      expect(result.perimeter, '18');
      expect(result.items, hasLength(1));
      expect(result.items.single.quantity, '100.000000');
      expect(result.totalCost, '43100.00');
      expect(result.warnings.single.code, 'product_missing');
    });

    test('perimeter null olabilir (alan yalnız area ile verilmişse)', () {
      final json = {
        'category': {'id': 'c1', 'slug': 's', 'name': 'N'},
        'input': {'footprint_area': '20', 'effective_area': '20', 'perimeter': null},
        'items': <Map<String, dynamic>>[],
        'total_cost': '0.00',
        'warnings': <Map<String, dynamic>>[],
      };

      final result = CalcRunResult.fromJson(json);

      expect(result.perimeter, isNull);
    });
  });

  group('Formatters — calc string alanları yalnız GÖRÜNTÜLEME için parse edilir', () {
    test('quantityFromString gereksiz sıfırları kırpar', () {
      expect(Formatters.quantityFromString('100.000000'), '100');
      expect(Formatters.quantityFromString('3.500000'), '3.5');
    });

    test('moneyFromString iki ondalıkla Türkçe biçimlendirir', () {
      expect(Formatters.moneyFromString('43100.00'), contains('43.100,00'));
    });
  });
}

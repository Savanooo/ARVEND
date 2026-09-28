import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/calc_admin/data/calc_admin_repository.dart';
import 'package:arvend/features/calc_admin/domain/calc_admin.dart';

import '../../test_utils/fake_api_client.dart';

Map<String, dynamic> _itemJson({String id = 'i1', String? productId = 'p1'}) => {
      'id': id,
      'category_id': 'c1',
      'product_id': ?productId,
      'material_name': 'Petek Panel',
      'unit': 'm²',
      'calculation_type': 'perimeter_based',
      'quantity_per_m2': '0',
      'quantity_per_meter': '1.050000',
      'fixed_quantity': '0',
      'waste_percent': '5',
      'rounding_type': 'ceil',
      'package_size': '3.6',
      'reference_unit_price': '185.50',
      'group_name': 'Ana Malzemeler',
      'sort_order': 3,
      'is_active': false,
    };

CalcRecipeItemInput _input({
  String? productId,
  String perM2 = '1,5',
  String minQuantity = '',
  String packageSize = '',
  String notes = '',
}) =>
    CalcRecipeItemInput(
      categoryId: 'c1',
      productId: productId,
      materialName: '  Petek Panel ',
      unit: ' m² ',
      calculationType: CalcType.areaBased,
      quantityPerM2: perM2,
      quantityPerMeter: '',
      fixedQuantity: '0',
      wastePercent: '',
      roundingType: CalcRounding.round,
      minQuantity: minQuantity,
      packageSize: packageSize,
      referenceUnitPrice: '12,75',
      groupName: ' Ana ',
      sortOrder: 4,
      isActive: true,
      notes: notes,
    );

void main() {
  group('parsing', () {
    test('CalcRecipeItem reads the exact backend field set (numbers as strings)', () {
      final item = CalcRecipeItem.fromJson(_itemJson());
      expect(item.productId, 'p1');
      expect(item.calculationType, CalcType.perimeterBased);
      expect(item.quantityPerMeter, '1.050000');
      expect(item.activeFactor, '1.050000');
      expect(item.minQuantity, isNull);
      expect(item.packageSize, '3.6');
      expect(item.notes, isNull);
      expect(item.sortOrder, 3);
      expect(item.isActive, isFalse);
    });

    test('omitted product_id (omitempty) means "not linked"', () {
      expect(CalcRecipeItem.fromJson(_itemJson(productId: null)).productId, isNull);
    });

    test('activeFactor follows the calculation type like the web table', () {
      final area = CalcRecipeItem.fromJson({..._itemJson(), 'calculation_type': 'area_based', 'quantity_per_m2': '2'});
      final fixed = CalcRecipeItem.fromJson({..._itemJson(), 'calculation_type': 'fixed', 'fixed_quantity': '7'});
      expect(area.activeFactor, '2');
      expect(fixed.activeFactor, '7');
    });

    test('CalcProductOption ignores supplier cost price / markup fields', () {
      final p = CalcProductOption.fromJson({
        'id': 'p1',
        'name': 'Panel',
        'unit': 'm²',
        'unit_price': 420,
        'source_price': 300,
        'markup_percent': 40,
      });
      expect(p.unitPrice, 420);
    });
  });

  group('helpers', () {
    test('slugify mirrors the web (Turkish letters, İ/I, separators)', () {
      expect(slugify('Petek Tavanlar'), 'petek-tavanlar');
      expect(slugify('İç Cephe Işıklığı'), 'ic-cephe-isikligi');
      expect(slugify('  10x10 Petek / Tavan  '), '10x10-petek-tavan');
      expect(slugify('Çatı Örtüsü Ğ Ş Ü'), 'cati-ortusu-g-s-u');
    });

    test('searchFold matches upper-case Turkish catalog names (İ/I/ı)', () {
      expect(searchFold('DEMİR PROFİL 40x40'), contains(searchFold('demir')));
      expect(searchFold('KUTU PROFIL'), contains(searchFold('profil')));
      expect(searchFold('Işıklık Paneli'), contains(searchFold('ışık')));
      expect(searchFold('IŞIKLIK'), contains(searchFold('işık')));
      expect(searchFold('ÇELİK'), 'çelik');
    });

    test('normalizeDecimal turns a Turkish comma into a dot, empty -> null', () {
      expect(normalizeDecimal('1,25'), '1.25');
      expect(normalizeDecimal(' 3.6 '), '3.6');
      expect(normalizeDecimal('   '), isNull);
    });

    test('validateDecimalField mirrors the backend rules', () {
      expect(validateDecimalField('', label: 'Fire (%)'), isNull);
      expect(validateDecimalField('2,5', label: 'Fire (%)'), isNull);
      expect(validateDecimalField('abc', label: 'Fire (%)'), 'Fire (%) geçerli bir sayı olmalı');
      expect(validateDecimalField('-1', label: 'Fire (%)'), 'Fire (%) negatif olamaz');
      expect(validateDecimalField('0', label: 'Paket', positive: true), "Paket 0'dan büyük olmalı");
    });

    test('recipe input serializes like the web payload', () {
      final json = _input().toJson();
      expect(json['category_id'], 'c1');
      expect(json['product_id'], isNull);
      expect(json['material_name'], 'Petek Panel');
      expect(json['unit'], 'm²');
      expect(json['quantity_per_m2'], '1.5');
      expect(json['quantity_per_meter'], '0');
      expect(json['waste_percent'], '0');
      expect(json['reference_unit_price'], '12.75');
      expect(json['min_quantity'], isNull);
      expect(json['package_size'], isNull);
      expect(json['group_name'], 'Ana');
      expect(json['sort_order'], 4);
      expect(json['is_active'], isTrue);
      expect(json['notes'], isNull);
      expect(json['rounding_type'], 'round');
    });
  });

  group('repository', () {
    test('createGroup POSTs slug/name/description/sort_order and derives a missing slug', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/groups': [
          (
            status: 201,
            body: {'id': 'g9', 'slug': 'petek-tavanlar', 'name': 'Petek Tavanlar', 'description': '', 'sort_order': 0, 'is_active': true}
          ),
        ],
      });
      final repo = CalcAdminRepository(await buildFakeApiClient(adapter));
      final g = await repo.createGroup(name: 'Petek Tavanlar', slug: '', description: '');
      expect(g.id, 'g9');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body, {'slug': 'petek-tavanlar', 'name': 'Petek Tavanlar', 'description': '', 'sort_order': 0});
    });

    test('categories() uses the flat ?group_id= shape', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/categories': [
          (
            status: 200,
            body: {
              'categories': [
                {'id': 'c1', 'group_id': 'g1', 'slug': 's', 'name': 'N', 'description': '', 'sort_order': 1, 'is_active': true},
              ],
            }
          ),
        ],
      });
      final repo = CalcAdminRepository(await buildFakeApiClient(adapter));
      final cats = await repo.categories('g1');
      expect(cats.single.name, 'N');
      expect(adapter.requestQueries.single, {'group_id': 'g1'});
    });

    test('updateCategory keeps the existing image_file_id (no image editing on mobile)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/categories/c1': [
          (
            status: 200,
            body: {'id': 'c1', 'group_id': 'g1', 'slug': 'yeni', 'name': 'Yeni', 'description': '', 'image_file_id': 'img-1', 'sort_order': 2, 'is_active': false}
          ),
        ],
      });
      final repo = CalcAdminRepository(await buildFakeApiClient(adapter));
      const existing = CalcAdminCategory(
        id: 'c1',
        groupId: 'g1',
        slug: 'eski',
        name: 'Eski',
        description: '',
        imageFileId: 'img-1',
        sortOrder: 1,
        isActive: true,
      );
      await repo.updateCategory(existing, name: 'Yeni', slug: 'yeni', description: '', sortOrder: 2, isActive: false);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['group_id'], 'g1');
      expect(body['image_file_id'], 'img-1');
      expect(body['is_active'], isFalse);
      expect(body['sort_order'], 2);
    });

    test('recipe item create/update/delete hit the right endpoints', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/recipe-items': [(status: 201, body: _itemJson(id: 'i9'))],
        '/calculations/recipe-items/i9': [(status: 200, body: _itemJson(id: 'i9')), (status: 200, body: {'ok': true})],
      });
      final repo = CalcAdminRepository(await buildFakeApiClient(adapter));
      await repo.createRecipeItem(_input(productId: 'p1'));
      await repo.updateRecipeItem('i9', _input(productId: 'p1', packageSize: '3,6'));
      await repo.deleteRecipeItem('i9');
      expect(adapter.calls, ['/calculations/recipe-items', '/calculations/recipe-items/i9', '/calculations/recipe-items/i9']);
      expect((adapter.requestBodies[0] as Map)['product_id'], 'p1');
      expect((adapter.requestBodies[1] as Map)['package_size'], '3.6');
    });

    test('allProducts pages through the whole catalog with limit=200', () async {
      Map<String, dynamic> page(int from, int count) => {
            'products': [
              for (var i = from; i < from + count; i++) {'id': 'p$i', 'name': 'Ürün $i', 'unit': 'adet', 'unit_price': 1},
            ],
            'total': 450,
          };
      final adapter = FakeHttpClientAdapter(script: {
        '/products': [(status: 200, body: page(0, 200)), (status: 200, body: page(200, 200)), (status: 200, body: page(400, 50))],
      });
      final repo = CalcAdminRepository(await buildFakeApiClient(adapter));
      final products = await repo.allProducts();
      expect(products, hasLength(450));
      expect(adapter.requestQueries.map((q) => q['page']), [1, 2, 3]);
      expect(adapter.requestQueries.every((q) => q['limit'] == 200), isTrue);
    });
  });
}

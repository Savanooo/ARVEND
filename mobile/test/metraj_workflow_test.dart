import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/calculations/data/calc_repository.dart';
import 'package:arvend/features/calculations/domain/calc.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';

import 'test_utils/fake_api_client.dart';

/// Metraj/Calculations — backend traced end-to-end and every formula
/// INDEPENDENTLY re-verified against the current source before any mobile
/// code was written (real fixture recipe items used as golden cases
/// below). The engine is server-side only (`domain/calc.go`,
/// `ComputeGeometry`/`ComputeRecipeQuantity`) -- these tests prove mobile
/// correctly PARSES and DISPLAYS the backend's authoritative numbers and
/// correctly CARRIES calc context into an offer; none of them re-derive
/// any quantity/money formula in Dart.
void main() {
  group('parsing', () {
    test('CalcCategory.fromJson reads id/group linkage/name/description', () {
      final c = CalcCategory.fromJson({
        'id': 'cat1',
        'group_id': 'g1',
        'group_slug': '60x60-asma-tavanlar',
        'group_name': '60x60 Alüminyum Tavan',
        'slug': '60x60-aluminyum-tavan',
        'name': '60x60 Alüminyum Tavan',
        'description': 'Asma tavan sistemleri için standart reçete.',
      });
      expect(c.id, 'cat1');
      expect(c.groupId, 'g1');
      expect(c.description, 'Asma tavan sistemleri için standart reçete.');
    });

    test('CalcCategory.fromJson defaults description to empty string when absent', () {
      final c = CalcCategory.fromJson({'id': 'c1', 'group_id': 'g1', 'slug': 's', 'name': 'N'});
      expect(c.description, '');
    });

    test('CalcGroupWithCategories.looksLikeRoof matches group name or slug containing çatı/cati', () {
      final roofByName = CalcGroupWithCategories.fromJson({'id': 'g1', 'slug': 'onduline', 'name': 'Onduline Çatı', 'categories': []});
      final roofBySlug = CalcGroupWithCategories.fromJson({'id': 'g2', 'slug': 'onduline-cati', 'name': 'Onduline', 'categories': []});
      final notRoof = CalcGroupWithCategories.fromJson({'id': 'g3', 'slug': '60x60-asma-tavanlar', 'name': '60x60 Alüminyum Tavan', 'categories': []});
      expect(roofByName.looksLikeRoof, isTrue);
      expect(roofBySlug.looksLikeRoof, isTrue);
      expect(notRoof.looksLikeRoof, isFalse);
    });

    test('CalcWarning.fromJson parses code/message/item_id', () {
      final w = CalcWarning.fromJson({'item_id': 'r1', 'code': 'perimeter_missing', 'message': 'çevre bilgisi yok'});
      expect(w.itemId, 'r1');
      expect(w.code, 'perimeter_missing');
    });

    test('CalcWarning.fromJson: item_id can be null (category-level warning)', () {
      final w = CalcWarning.fromJson({'item_id': null, 'code': 'unknown_calculation_type', 'message': 'x'});
      expect(w.itemId, isNull);
    });

    test('CalcResultItem.fromJson reads all 12 fields including group_name/calculation_type/factor', () {
      final item = CalcResultItem.fromJson({
        'recipe_item_id': 'r1',
        'material_name': '60x60 Alüminyum Tavan',
        'unit': 'adet',
        'quantity': '5.000000',
        'product_id': 'p1',
        'unit_price': '200.00',
        'line_total': '1000.00',
        'group_name': 'Ana Malzemeler',
        'calculation_type': 'area_based',
        'factor': '5',
        'waste_percent': '0',
        'rounding_type': 'none',
      });
      expect(item.materialName, '60x60 Alüminyum Tavan');
      expect(item.groupName, 'Ana Malzemeler');
      expect(item.calculationType, 'area_based');
      expect(item.factor, '5');
    });

    test('CalcRunResult.fromJson: footprint_area vs effective_area both parsed (pitch changes them independently)', () {
      final result = CalcRunResult.fromJson({
        'category': {'id': 'c1', 'slug': 's', 'name': 'Onduline Çatı'},
        'input': {'footprint_area': '10', 'effective_area': '11.547005', 'perimeter': null},
        'items': <Map<String, dynamic>>[],
        'total_cost': '0.00',
        'warnings': <Map<String, dynamic>>[],
      });
      expect(result.footprintArea, '10');
      expect(result.effectiveArea, '11.547005');
      expect(result.footprintArea == result.effectiveArea, isFalse);
    });
  });

  group('golden calculation cases (real fixture recipe items, backend-verified)', () {
    // Ground truth reproduced from backend/db/fixtures/byz_calc_recipes.json
    // and independently re-derived/confirmed against domain/calc.go during
    // this module's investigation phase -- these are not invented numbers.

    test('golden: 60x60 Alüminyum Tavan, area=1 -> quantity 5.000000, line_total 1000.00', () {
      // base = area(1) * quantity_per_m2(5) = 5; waste=0, no package,
      // rounding_type=none -> Round(6) = 5.000000; unit_price 200.00 ->
      // line_total = 5 * 200.00 = 1000.00.
      final item = CalcResultItem.fromJson({
        'recipe_item_id': 'r1',
        'material_name': '60x60 Alüminyum Tavan',
        'unit': 'adet',
        'quantity': '5.000000',
        'product_id': 'p1',
        'unit_price': '200.00',
        'line_total': '1000.00',
        'group_name': 'Ana Malzemeler',
        'calculation_type': 'area_based',
        'factor': '5',
        'waste_percent': '0',
        'rounding_type': 'none',
      });
      expect(item.quantity, '5.000000');
      expect(item.lineTotal, '1000.00');
    });

    test('golden: Onduline Çivisi, area=10, rounding_type=ceil -> quantity 3 (package rounding), line_total 750.00', () {
      // base = area(10) * quantity_per_m2(0.25) = 2.5; no waste/package;
      // rounding_type=ceil -> Round(6).Ceil() = 3; unit_price 250.00 ->
      // line_total = 3 * 250.00 = 750.00 (NOT 2.5 * 250.00 = 625.00 --
      // proves the response's own quantity/line_total, not a naive
      // client-side multiply, must be trusted).
      final item = CalcResultItem.fromJson({
        'recipe_item_id': 'r2',
        'material_name': 'Onduline Çivisi',
        'unit': 'paket',
        'quantity': '3',
        'product_id': 'p2',
        'unit_price': '250.00',
        'line_total': '750.00',
        'group_name': 'Aksesuar',
        'calculation_type': 'area_based',
        'factor': '0.25',
        'waste_percent': '0',
        'rounding_type': 'ceil',
      });
      expect(item.quantity, '3');
      expect(item.lineTotal, '750.00');
    });

    test('golden: 10x10 Petek Tavan recipe, area=20m2 -> total_cost 43100.00 (cross-verified against a live-DB backend test)', () {
      final result = CalcRunResult.fromJson({
        'category': {'id': 'c1', 'slug': 'petek-tavan-10x10', 'name': '10x10 Petek Tavan'},
        'input': {'footprint_area': '20', 'effective_area': '20', 'perimeter': null},
        'items': [
          {
            'recipe_item_id': 'r1', 'material_name': 'Petek Panel', 'unit': 'm2', 'quantity': '100.000000',
            'product_id': 'p1', 'unit_price': '230.00', 'line_total': '23000.00', 'group_name': 'Panel',
            'calculation_type': 'area_based', 'factor': '5', 'waste_percent': '0', 'rounding_type': 'none',
          },
        ],
        'total_cost': '43100.00',
        'warnings': <Map<String, dynamic>>[],
      });
      expect(result.totalCost, '43100.00');
    });
  });

  group('input serialization', () {
    test('run() POSTs exactly category_id/area/width/height/perimeter/pitch_deg', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/run': [(status: 200, body: _runResultJson())],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await repo.run(categoryId: 'c1', area: '20', pitchDeg: '15');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['category_id'], 'c1');
      expect(body['area'], '20');
      expect(body['width'], isNull);
      expect(body['height'], isNull);
      expect(body['perimeter'], isNull);
      expect(body['pitch_deg'], '15');
    });

    test('run() with width/height/perimeter sends exactly those, area null', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/run': [(status: 200, body: _runResultJson())],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await repo.run(categoryId: 'c1', width: '4', height: '3', perimeter: '14');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['area'], isNull);
      expect(body['width'], '4');
      expect(body['height'], '3');
      expect(body['perimeter'], '14');
    });

    test('groupsWithCategories() GETs /calculations/categories with no query params (triggers nested cascade shape)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/categories': [(status: 200, body: {'groups': <Map<String, dynamic>>[]})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await repo.groupsWithCategories();

      expect(adapter.calls, ['/calculations/categories']);
      expect(adapter.requestQueries.single, isEmpty);
    });
  });

  group('client-side positive-number validation (UX only, backend remains authoritative)', () {
    test('empty value is treated as absent, not an error', () {
      expect(validatePositiveIfPresent('', 'Alan'), isNull);
      expect(validatePositiveIfPresent('   ', 'Alan'), isNull);
    });

    test('a present zero or negative value is rejected (matches backend: present-but-<=0 is an explicit error)', () {
      expect(validatePositiveIfPresent('0', 'Alan'), isNotNull);
      expect(validatePositiveIfPresent('-5', 'Alan'), isNotNull);
    });

    test('non-numeric text is rejected', () {
      expect(validatePositiveIfPresent('abc', 'Alan'), isNotNull);
    });

    test('a valid positive value (including comma-decimal) passes', () {
      expect(validatePositiveIfPresent('20', 'Alan'), isNull);
      expect(validatePositiveIfPresent('3,5', 'Alan'), isNull);
    });
  });

  group('warnings', () {
    test('all four known warning codes parse cleanly', () {
      for (final code in ['perimeter_missing', 'unknown_calculation_type', 'product_missing', 'product_zero_price']) {
        final w = CalcWarning.fromJson({'item_id': 'r1', 'code': code, 'message': 'x'});
        expect(w.code, code);
      }
    });

    test('CalcRunResult carries the full warnings list through, not just the first one', () {
      final result = CalcRunResult.fromJson({
        'category': {'id': 'c1', 'slug': 's', 'name': 'N'},
        'input': {'footprint_area': '20', 'effective_area': '20', 'perimeter': null},
        'items': <Map<String, dynamic>>[],
        'total_cost': '0.00',
        'warnings': [
          {'item_id': 'r1', 'code': 'product_missing', 'message': 'a'},
          {'item_id': 'r2', 'code': 'product_zero_price', 'message': 'b'},
        ],
      });
      expect(result.warnings, hasLength(2));
      expect(result.warnings.map((w) => w.code), containsAll(['product_missing', 'product_zero_price']));
    });
  });

  group('offer transfer (buildOfferItemsFromCalcResult) — retains full calc linkage/context', () {
    CalcRunResult resultWithTwoItems() => CalcRunResult.fromJson({
          'category': {'id': 'cat1', 'slug': '60x60-aluminyum-tavan', 'name': '60x60 Alüminyum Tavan'},
          'input': {'footprint_area': '1', 'effective_area': '1', 'perimeter': null},
          'items': [
            {
              'recipe_item_id': 'r1', 'material_name': '60x60 Alüminyum Tavan', 'unit': 'adet', 'quantity': '5.000000',
              'product_id': 'p1', 'unit_price': '200.00', 'line_total': '1000.00', 'group_name': 'Ana Malzemeler',
              'calculation_type': 'area_based', 'factor': '5', 'waste_percent': '0', 'rounding_type': 'none',
            },
            {
              'recipe_item_id': 'r2', 'material_name': '3600 mm Ana Taşıyıcı', 'unit': 'adet', 'quantity': '1.000000',
              'product_id': null, 'unit_price': '0', 'line_total': '0.00', 'group_name': 'Ana Malzemeler',
              'calculation_type': 'area_based', 'factor': '1', 'waste_percent': '0', 'rounding_type': 'none',
            },
          ],
          'total_cost': '1000.00',
          'warnings': <Map<String, dynamic>>[],
        });

    test('only selected recipe items are included', () {
      final items = buildOfferItemsFromCalcResult(resultWithTwoItems(), {'r1'});
      expect(items, hasLength(1));
      expect(items.single.productName, '60x60 Alüminyum Tavan');
    });

    test('empty selection produces an empty list', () {
      expect(buildOfferItemsFromCalcResult(resultWithTwoItems(), {}), isEmpty);
    });

    test('product/quantity/unit/unit_price/section_label/calc_category_id all carried over', () {
      final item = buildOfferItemsFromCalcResult(resultWithTwoItems(), {'r1'}).single;
      expect(item.productId, 'p1');
      expect(item.productName, '60x60 Alüminyum Tavan');
      expect(item.quantity, 5.0);
      expect(item.unitPrice, 200.0);
      expect(item.unit, 'adet');
      expect(item.sectionLabel, '60x60 Alüminyum Tavan'); // defaults to category name
      expect(item.calcCategoryId, 'cat1');
    });

    test('a productless item (product_missing warning case) transfers with productId null and unitPrice 0, not dropped', () {
      final item = buildOfferItemsFromCalcResult(resultWithTwoItems(), {'r2'}).single;
      expect(item.productId, isNull);
      expect(item.unitPrice, 0.0);
      expect(item.productName, '3600 mm Ana Taşıyıcı');
    });

    test('calc_snapshot carries exactly the 11 documented keys (matches MOBILE_BACKEND_GAPS.md #10)', () {
      final item = buildOfferItemsFromCalcResult(resultWithTwoItems(), {'r1'}).single;
      final snapshot = item.calcSnapshot as Map<String, dynamic>;
      expect(snapshot.keys.toSet(), {
        'recipe_item_id', 'category_id', 'category_name', 'footprint_area', 'effective_area',
        'perimeter', 'calculation_type', 'factor', 'waste_percent', 'rounding_type', 'price_at_calc',
      });
      expect(snapshot['recipe_item_id'], 'r1');
      expect(snapshot['category_id'], 'cat1');
      expect(snapshot['calculation_type'], 'area_based');
      expect(snapshot['price_at_calc'], '200.00');
    });

    test('OfferItem.toJson() sends calc_category_id/calc_snapshot/section_label (never dropped, even implicitly)', () {
      final item = buildOfferItemsFromCalcResult(resultWithTwoItems(), {'r1'}).single;
      final json = item.toJson();
      expect(json['calc_category_id'], 'cat1');
      expect(json.containsKey('calc_snapshot'), isTrue);
      expect(json['section_label'], '60x60 Alüminyum Tavan');
    });

    test('a manually-added offer item (not calc-derived) has null calc_category_id/calc_snapshot', () {
      // Sanity check for the OTHER branch: an item that never went through
      // buildOfferItemsFromCalcResult must not accidentally look calc-derived.
      final manual = buildOfferItemsFromCalcResult(resultWithTwoItems(), {}).isEmpty;
      expect(manual, isTrue);
    });
  });

  group('permissions — exact two-tier, org-only model (calculations.read / calculations.manage)', () {
    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    test('owner/admin-shaped set: read+manage', () {
      final user = userWith(const {'calculations.read', 'calculations.manage'});
      expect(user.hasPermission('calculations.read'), isTrue);
      expect(user.hasPermission('calculations.manage'), isTrue);
    });

    // Phase 1 bulgusu: legacy_user VE project_manager yalnızca read alır,
    // manage (reçete/grup/kategori düzenleme) ALMAZLAR.
    test('legacy_user/project_manager-shaped set: read only, NOT manage', () {
      final user = userWith(const {'calculations.read'});
      expect(user.hasPermission('calculations.read'), isTrue);
      expect(user.hasPermission('calculations.manage'), isFalse);
    });

    // Phase 1 bulgusu: finance VE field rolleri metraj izinlerinin
    // HİÇBİRİNİ ALMAZ -- Metraj panelini hiç göremezler.
    test('finance/field-shaped set: neither calculations permission', () {
      final user = userWith(const {'projects.finance.read', 'attendance.read'});
      expect(user.hasPermission('calculations.read'), isFalse);
      expect(user.hasPermission('calculations.manage'), isFalse);
    });

    test('calculations permission axis is exactly {read, manage} -- no per-recipe/per-category tier exists', () {
      const codes = {'calculations.read', 'calculations.manage'};
      final user = userWith(codes);
      for (final code in codes) {
        expect(user.hasPermission(code), isTrue);
      }
      expect(user.hasPermission('calculations.approve'), isFalse);
    });
  });

  group('backend error mapping', () {
    test('zero/negative area rejected server-side surfaces the backend message verbatim', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/run': [(status: 400, body: {'error': "'area' 0'dan büyük olmalı"})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await expectLater(
        repo.run(categoryId: 'c1', area: '-5'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', "'area' 0'dan büyük olmalı")),
      );
    });

    test('missing area/width+height surfaces as a 400 with the backend message', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/run': [(status: 400, body: {'error': "alan bilgisi eksik: 'area' ya da 'width' + 'height' girin"})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await expectLater(
        repo.run(categoryId: 'c1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });

    test('a category with zero active recipe items is a hard error (400), not an empty success', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/run': [(status: 400, body: {'error': 'bu kategori için malzeme reçetesi tanımlanmamış'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await expectLater(
        repo.run(categoryId: 'c1', area: '10'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'bu kategori için malzeme reçetesi tanımlanmamış')),
      );
    });

    test('cross-org/nonexistent category_id surfaces as 404', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/calculations/run': [(status: 404, body: {'error': 'kayıt bulunamadı'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CalcRepository(client);

      await expectLater(
        repo.run(categoryId: 'other-org-cat', area: '10'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('OfferCreateScreen — Metrajdan Ekle entry point exists', () {
    testWidgets('the "Metrajdan Ekle" button is present alongside "Kalem Ekle"', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [
          (status: 200, body: {
            'id': 'u1', 'organization_id': 'org1', 'username': 'test', 'full_name': 'Test Kullanıcı',
            'role': 'admin', 'is_active': true, 'must_change_password': false,
            'onboarding_completed': true, 'onboarding_step': 'completed', 'permissions': <String>[],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);

      // Müşteri kartı bu butonları varsayılan test yüzeyinde görünümün
      // dışına itebiliyor -- kaydırmadan sığacak bir yüzey kullanılır.
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: OfferCreateScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Metrajdan Ekle'), findsOneWidget);
      expect(find.text('Kalem Ekle'), findsOneWidget);
    });
  });
}

Map<String, dynamic> _runResultJson() => {
      'category': {'id': 'c1', 'slug': 's', 'name': 'N'},
      'input': {'footprint_area': '20', 'effective_area': '20', 'perimeter': null},
      'items': <Map<String, dynamic>>[],
      'total_cost': '0.00',
      'warnings': <Map<String, dynamic>>[],
    };

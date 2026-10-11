import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/calculations/domain/calc.dart';
import 'package:arvend/features/calculations/presentation/metraj_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Metraj ekranının sunucuya ne gönderdiği ve eski sonucu ne zaman
/// bıraktığı: çatı eğimi yalnızca çatı grubunda gider, ölçü değişince
/// eski sonuç teklife taşınamaz.

Map<String, dynamic> _catalog() => {
      'groups': [
        {
          'id': 'g-cati', 'slug': 'cati-hesaplamalari', 'name': 'Çatı Hesaplamaları',
          'categories': [
            {'id': 'cat-onduline', 'group_id': 'g-cati', 'slug': 'onduline', 'name': 'Onduline Çatı', 'description': ''},
          ],
        },
        {
          'id': 'g-tavan', 'slug': 'alcipan-asma-tavanlar', 'name': 'Alçıpan Asma Tavanlar',
          'categories': [
            {'id': 'cat-alcipan', 'group_id': 'g-tavan', 'slug': 'alcipan', 'name': 'Alçıpan Tavan', 'description': ''},
          ],
        },
      ],
    };

Map<String, dynamic> _run(String categoryId, String name) => {
      'category': {'id': categoryId, 'slug': 's', 'name': name},
      'input': {'footprint_area': '100', 'effective_area': '100', 'perimeter': null},
      'items': [
        {
          'recipe_item_id': 'r1', 'material_name': 'Malzeme', 'unit': 'adet', 'quantity': '10',
          'product_id': 'p1', 'unit_price': '5.00', 'line_total': '50.00', 'group_name': '',
          'calculation_type': 'area_based', 'factor': '0.1', 'waste_percent': '0', 'rounding_type': 'none',
          'price_source': 'product',
        },
      ],
      'total_cost': '50.00',
      'warnings': <Map<String, dynamic>>[],
    };

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(500, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => FakeAuth(testUser({'calculations.read', 'offers.create'}))),
    ],
    child: const MaterialApp(home: MetrajScreen()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pickGroup(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<CalcGroupWithCategories>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Finder get _pitchField => find.widgetWithText(TextField, 'Çatı Eğimi (derece) — opsiyonel');

void main() {
  testWidgets('çatıda girilen eğim başka gruba geçince gönderilmez ve temizlenir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      '/calculations/run': [
        (status: 200, body: _run('cat-onduline', 'Onduline Çatı')),
        (status: 200, body: _run('cat-alcipan', 'Alçıpan Tavan')),
      ],
    });
    await _pump(tester, adapter);

    await _pickGroup(tester, 'Çatı Hesaplamaları');
    await tester.tap(find.text('Onduline Çatı'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.enterText(_pitchField, '30');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();

    final roofBody = adapter.requestBodies.last as Map<String, dynamic>;
    expect(roofBody['category_id'], 'cat-onduline');
    expect(roofBody['pitch_deg'], '30');

    await _pickGroup(tester, 'Alçıpan Asma Tavanlar');
    expect(_pitchField, findsNothing);
    await tester.tap(find.text('Alçıpan Tavan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();

    final otherBody = adapter.requestBodies.last as Map<String, dynamic>;
    expect(otherBody['category_id'], 'cat-alcipan');
    expect(otherBody['area'], '100');
    expect(otherBody['pitch_deg'], isNull, reason: 'gizli eğim başka grubun hesabını şişirmemeli');

    // Çatıya geri dönünce eski eğim alanda kalmamış olmalı.
    await _pickGroup(tester, 'Çatı Hesaplamaları');
    await tester.tap(find.text('Onduline Çatı'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_pitchField).controller!.text, isEmpty);
  });

  testWidgets('ölçü değişince eski sonuç ve "Teklife Ekle" kalkar', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      '/calculations/run': [(status: 200, body: _run('cat-alcipan', 'Alçıpan Tavan'))],
    });
    await _pump(tester, adapter);

    await _pickGroup(tester, 'Alçıpan Asma Tavanlar');
    await tester.tap(find.text('Alçıpan Tavan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();
    expect(find.text('Teklife Ekle (1)'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '120');
    await tester.pumpAndSettle();
    expect(find.text('Malzeme Listesi'), findsNothing);
    expect(find.textContaining('Teklife Ekle'), findsNothing);
  });
}

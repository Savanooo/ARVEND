import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/widgets/app_list_card.dart';
import 'package:arvend/features/calculations/data/calc_providers.dart';
import 'package:arvend/features/calculations/data/calc_repository.dart';
import 'package:arvend/features/calculations/domain/calc.dart';
import 'package:arvend/features/calculations/presentation/metraj_screen.dart';
import 'package:arvend/features/offers/domain/offer.dart';

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

/// Doğrudan Alan modunda çevre girilmeyince çevre bazlı kalem 0 döner.
Map<String, dynamic> _runWithZeroLine() {
  final json = _run('cat-alcipan', 'Alçıpan Tavan');
  (json['items'] as List).add({
    'recipe_item_id': 'r-kenar', 'material_name': 'Kenar Profili', 'unit': 'm', 'quantity': '0',
    'product_id': 'p2', 'unit_price': '12.00', 'line_total': '0.00', 'group_name': '',
    'calculation_type': 'perimeter_based', 'factor': '1', 'waste_percent': '0', 'rounding_type': 'none',
    'price_source': 'product',
  });
  json['warnings'] = [
    {'item_id': 'r-kenar', 'code': 'perimeter_missing', 'message': '"Kenar Profili" çevre bazlı hesaplanıyor ama çevre yok'},
  ];
  return json;
}

/// Yavaş şebeke: her /calculations/run çağrısı, test [release] diyene kadar
/// bekler (istek gövdesi yine sahte adaptörde kaydedilir).
class _SlowCalcRepository extends CalcRepository {
  _SlowCalcRepository(super.client);

  final _gates = <Completer<void>>[];

  void release() => _gates.removeAt(0).complete();

  @override
  Future<CalcRunResult> run({
    required String categoryId,
    String? area,
    String? width,
    String? height,
    String? perimeter,
    String? pitchDeg,
  }) async {
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    return super.run(
      categoryId: categoryId,
      area: area,
      width: width,
      height: height,
      perimeter: perimeter,
      pitchDeg: pitchDeg,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  FakeHttpClientAdapter adapter, {
  Widget home = const MetrajScreen(),
  CalcRepository Function(ApiClient client)? repository,
}) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(500, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => FakeAuth(testUser({'calculations.read', 'offers.create'}))),
      if (repository != null) calcRepositoryProvider.overrideWithValue(repository(client)),
    ],
    child: MaterialApp(home: home),
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

  testWidgets('miktarı 0 olan satır seçili gelmez ve seçilemez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      '/calculations/run': [(status: 200, body: _runWithZeroLine())],
    });
    await _pump(tester, adapter);

    await _pickGroup(tester, 'Alçıpan Asma Tavanlar');
    await tester.tap(find.text('Alçıpan Tavan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();

    expect(find.text('Teklife Ekle (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('metraj-zero-qty-r-kenar')), findsOneWidget);
    expect(find.byKey(const ValueKey('metraj-zero-qty-r1')), findsNothing);
    final zeroBox = tester.widget<Checkbox>(
      find.descendant(of: find.ancestor(of: find.text('Kenar Profili'), matching: find.byType(AppListCard)), matching: find.byType(Checkbox)),
    );
    expect(zeroBox.value, isFalse);
    expect(zeroBox.onChanged, isNull);

    await tester.tap(find.text('Kenar Profili'));
    await tester.pumpAndSettle();
    expect(find.text('Teklife Ekle (1)'), findsOneWidget);
  });

  test('teklife aktarımda miktarı 0 olan satır seçili olsa bile atlanır', () {
    final result = CalcRunResult.fromJson(_runWithZeroLine());
    final items = buildOfferItemsFromCalcResult(result, {'r1', 'r-kenar'});
    expect(items.map((i) => i.productName), ['Malzeme']);
    expect(result.items.map((i) => i.hasOfferQuantity), [true, false]);
    // 0,01'in altındaki miktar teklifte 0,00 olurdu; o da eklenemez.
    final tiny = CalcResultItem.fromJson({...(_runWithZeroLine()['items'] as List).first as Map<String, dynamic>, 'quantity': '0.004'});
    expect(tiny.hasOfferQuantity, isFalse);
  });

  testWidgets('Teklife Ekle: snapshot hesapta kullanılan eğimi ve grubu kanonik şemada taşır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      // input.pitch_deg'i göndermeyen sunucu: istekteki eğim yazılır.
      '/calculations/run': [(status: 200, body: _run('cat-onduline', 'Onduline Çatı'))],
    });
    List<OfferItem>? picked;
    await _pump(
      tester,
      adapter,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await Navigator.of(context).push<List<OfferItem>>(
              MaterialPageRoute(builder: (_) => const MetrajScreen(pickMode: true)),
            );
          },
          child: const Text('Metrajdan Ekle'),
        ),
      ),
    );
    await tester.tap(find.text('Metrajdan Ekle'));
    await tester.pumpAndSettle();

    await _pickGroup(tester, 'Çatı Hesaplamaları');
    await tester.tap(find.text('Onduline Çatı'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.enterText(_pitchField, '30');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Teklife Ekle (1)'));
    await tester.pumpAndSettle();

    final snapshot = picked!.single.calcSnapshot as Map<String, dynamic>;
    expect(snapshot['pitch_deg'], '30');
    expect(snapshot['group_name'], 'Çatı Hesaplamaları');
    expect(snapshot['area'], '100');
    expect(snapshot['recipe_factor'], '0.1');
    expect(snapshot['price_source'], 'product');
  });

  testWidgets('yanıt beklenirken ölçü değişirse gelen eski sonuç gösterilmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      '/calculations/run': [
        (status: 200, body: _run('cat-alcipan', 'Alçıpan Tavan')),
        (status: 200, body: _run('cat-alcipan', 'Alçıpan Tavan')),
      ],
    });
    late _SlowCalcRepository repo;
    await _pump(tester, adapter, repository: (c) => repo = _SlowCalcRepository(c));

    await _pickGroup(tester, 'Alçıpan Asma Tavanlar');
    await tester.tap(find.text('Alçıpan Tavan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.tap(find.text('Hesapla'));
    await tester.pump();

    // Yavaş şebeke: kullanıcı yanıt gelmeden alanı düzeltiyor.
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '120');
    await tester.pump();
    repo.release();
    await tester.pumpAndSettle();

    expect(find.text('Malzeme Listesi'), findsNothing, reason: '100 m² sonucu 120 yazan formun yanında görünmemeli');
    expect(find.textContaining('Teklife Ekle'), findsNothing);

    // Yeniden hesaplayınca güncel ölçünün sonucu gelir.
    await tester.tap(find.text('Hesapla'));
    await tester.pump();
    repo.release();
    await tester.pumpAndSettle();
    expect((adapter.requestBodies.last as Map<String, dynamic>)['area'], '120');
    expect(find.text('Teklife Ekle (1)'), findsOneWidget);
  });

  testWidgets('yanıt beklenirken grup değişirse eski kategorinin sonucu gelmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      '/calculations/run': [(status: 200, body: _run('cat-onduline', 'Onduline Çatı'))],
    });
    late _SlowCalcRepository repo;
    await _pump(tester, adapter, repository: (c) => repo = _SlowCalcRepository(c));

    await _pickGroup(tester, 'Çatı Hesaplamaları');
    await tester.tap(find.text('Onduline Çatı'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.enterText(_pitchField, '30');
    await tester.tap(find.text('Hesapla'));
    await tester.pump();

    await tester.tap(find.byType(DropdownButtonFormField<CalcGroupWithCategories>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Alçıpan Asma Tavanlar').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    repo.release();
    await tester.pumpAndSettle();

    expect(find.text('Onduline Çatı'), findsNothing);
    expect(find.text('Malzeme Listesi'), findsNothing, reason: 'çatı hesabı (eğimli) alçıpan grubunda görünmemeli');
    expect(find.textContaining('Teklife Ekle'), findsNothing);
  });

  testWidgets('90° ve üstü eğim sunucuya gitmeden reddedilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
    });
    await _pump(tester, adapter);

    await _pickGroup(tester, 'Çatı Hesaplamaları');
    await tester.tap(find.text('Onduline Çatı'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.enterText(_pitchField, '95');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();

    expect(find.text("Çatı Eğimi 90'dan küçük olmalı"), findsOneWidget);
    expect(adapter.calls, isNot(contains('/calculations/run')));
  });

  test('validatePitchIfPresent: boş serbest, (0, 90) aralığı dışı hata', () {
    expect(validatePitchIfPresent(''), isNull);
    expect(validatePitchIfPresent(' 30 '), isNull);
    expect(validatePitchIfPresent('89,9'), isNull);
    expect(validatePitchIfPresent('0'), "Çatı Eğimi 0'dan büyük olmalı");
    expect(validatePitchIfPresent('90'), "Çatı Eğimi 90'dan küçük olmalı");
    expect(validatePitchIfPresent('120'), "Çatı Eğimi 90'dan küçük olmalı");
    expect(validatePitchIfPresent('otuz'), 'Çatı Eğimi geçerli bir sayı olmalı');
  });

  testWidgets('eski sunucunun 0,01 altı miktarına "0" denmez', (tester) async {
    final json = _runWithZeroLine();
    ((json['items'] as List)[1] as Map<String, dynamic>)['quantity'] = '0.004000';
    final adapter = FakeHttpClientAdapter(script: {
      '/calculations/categories': [(status: 200, body: _catalog())],
      '/calculations/run': [(status: 200, body: json)],
    });
    await _pump(tester, adapter);

    await _pickGroup(tester, 'Alçıpan Asma Tavanlar');
    await tester.tap(find.text('Alçıpan Tavan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alan (m²)'), '100');
    await tester.tap(find.text('Hesapla'));
    await tester.pumpAndSettle();

    expect(find.text("Miktar 0,01'den küçük olduğu için teklife eklenmez"), findsOneWidget);
    expect(find.text('Teklife Ekle (1)'), findsOneWidget);
  });
}

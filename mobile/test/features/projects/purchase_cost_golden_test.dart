@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/projects/presentation/purchase_request_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../products/products_fakes.dart' show loadAppFonts, productsTestTheme;
import 'form_test_support.dart' show FakeAuth, testUser;

/// Satın alma talebinin proje maliyeti kararı (backend migration 0078), küçük
/// telefon (360x800): fiyatsız talebin onay sayfası (soru, uyarı, tahmini
/// tutar) ve onaylı talepte "Maliyete eklendi" kartı.
/// Üretmek:
///   flutter test --tags golden --update-goldens test/features/projects/purchase_cost_golden_test.dart

final _approver = testUser({'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve'});

Map<String, dynamic> _detail({required String status, required Map<String, dynamic> cost, bool priced = false}) => {
      'purchase_request': {
        'id': 'pr1', 'pr_no': 'PR-2026-0007', 'title': 'Şantiye kumu', 'description': 'Temel dolgusu için',
        'status': status, 'estimated_total': priced ? 11000 : 0, 'needed_by': '2026-11-05',
        'created_at': '2026-10-29T08:00:00Z', 'updated_at': '2026-10-29T08:00:00Z',
        'include_in_project_cost': true, 'cost_estimate': null, 'project_cost': cost,
      },
      'items': [
        {
          'id': 'i1', 'description': 'Dere kumu', 'quantity': 12, 'unit': 'ton',
          'estimated_unit_cost': priced ? 750 : null, 'estimated_total': priced ? 9000 : 0, 'notes': '', 'sort_order': 0,
        },
        {
          'id': 'i2', 'description': 'Nakliye', 'quantity': 1, 'unit': 'sefer',
          'estimated_unit_cost': priced ? 2000 : null, 'estimated_total': priced ? 2000 : 0, 'notes': '', 'sort_order': 1,
        },
      ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> detail) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(360, 800) * 2.0;
  addTearDown(tester.view.reset);
  final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {
    '/projects/p1/purchase-requests/pr1': [(status: 200, body: detail)],
  }));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => FakeAuth(_approver)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: productsTestTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const PurchaseRequestDetailScreen(projectId: 'p1', prId: 'pr1'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  testWidgets('approve sheet without prices', (tester) async {
    await _pump(tester, _detail(status: 'submitted', cost: {
      'included': true, 'amount': 0, 'potential': 0, 'source': 'none', 'unpriced_items': 2,
      'warning': 'Bu talepte fiyat yok; maliyete 0 TL girer.',
    }));
    await tester.tap(find.text('Onayla'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('maliyet-tahmin')), '11.000');
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/purchase_cost_approve_sheet_360x800.png'));
  });

  testWidgets('approved request cost card', (tester) async {
    await _pump(tester, _detail(status: 'approved', priced: true, cost: {
      'included': true, 'amount': 13200, 'potential': 13200, 'source': 'orders', 'unpriced_items': 0,
    }));

    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/purchase_cost_request_card_360x800.png'));
  });
}

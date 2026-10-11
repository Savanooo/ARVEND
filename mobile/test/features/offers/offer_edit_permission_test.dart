import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklif düzenleme (PUT /offers/{id}) offers.update ister. Detaydaki kalem
/// ikonu bu izne bakmıyordu ve /teklifler/:id/duzenle rotası korumasızdı:
/// izni olmayan formu doldurup kaydederken 403 alıyordu.

Map<String, dynamic> _draft() => {
      'id': 'o1',
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-09-20',
      'subtotal': 100,
      'vat_rate': 20,
      'vat_amount': 20,
      'grand_total': 120,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
      'items': [
        {'id': 'i1', 'product_name': 'Alçıpan', 'quantity': 1, 'unit_price': 100, 'line_total': 100, 'unit': 'm2'},
      ],
    };

Future<void> _pumpDetail(WidgetTester tester, Set<String> permissions) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/offers/o1': [(status: 200, body: _draft())],
    '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
    '/offers/o1/share-links': [(status: 200, body: {'share_links': <Object>[]})],
  });
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: '/teklifler/o1',
    routes: [
      GoRoute(path: '/teklifler/:id', builder: (c, s) => OfferDetailScreen(offerId: s.pathParameters['id']!)),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser(permissions))),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('offers.update yok: taslakta Düzenle ikonu görünmez', (tester) async {
    await _pumpDetail(tester, {'offers.read', 'offers.approve'});
    expect(find.byTooltip('Düzenle'), findsNothing);
  });

  testWidgets('offers.update var: taslakta Düzenle ikonu görünür', (tester) async {
    await _pumpDetail(tester, {'offers.read', 'offers.update'});
    expect(find.byTooltip('Düzenle'), findsOneWidget);
  });

  testWidgets('düzenleme rotası offers.update olmadan form açmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _draft())],
    });
    await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(offerId: 'o1'),
      user: testUser({'offers.read'}),
    );

    expect(find.text(kOfferEditNoAccessText), findsOneWidget);
    expect(find.text('Kaydet'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('yeni teklif rotası offers.create olmadan form açmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [(status: 403, body: {'error': 'bu işlem için yetkiniz yok', 'code': 'permission_denied'})],
    });
    await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(),
      user: testUser({'offers.read', 'offers.update'}),
    );

    expect(find.text(kOfferCreateNoAccessText), findsOneWidget);
    expect(find.text('Teklifi Oluştur'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('yeni teklif rotası offers.create ile form açar', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [(status: 200, body: {'vat_rate': 20, 'currency': 'TRY'})],
    });
    await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(),
      user: testUser({'offers.read', 'offers.create'}),
    );

    expect(find.text(kOfferCreateNoAccessText), findsNothing);
    expect(find.text('Teklifi Oluştur'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklifi arşive alma / arşivden çıkarma (POST /offers/{id}/toggle-passive,
/// offers.approve). Uç vardı ama hiçbir arayüze bağlı değildi: "Pasif"
/// sekmesi yalnızca BYZ'den gelen eski kayıtları gösteriyordu, vazgeçilen
/// teklifi geri çekmenin tek yolu silmekti.

Map<String, dynamic> _offer({bool passive = false}) => {
      'id': 'o1',
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-09-20',
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': 'gönderildi',
      'is_passive': passive,
      'items': <Object>[],
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required Set<String> permissions,
  required List<ScriptedResponse> offerResponses,
  List<ScriptedResponse> toggle = const [],
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/offers/o1': offerResponses,
    '/offers/o1/revisions': [for (var i = 0; i < 4; i++) (status: 200, body: {'revisions': <Object>[]})],
    '/offers/o1/share-links': [(status: 200, body: {'share_links': <Object>[]})],
    '/offers/o1/toggle-passive': toggle,
  });
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
  return adapter;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Diğer işlemler'));
  await tester.pumpAndSettle();
}

const _approver = {'offers.read', 'offers.update', 'offers.approve'};

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('"Arşivle" onaydan sonra hedef durumu gönderir; detay arşiv notunu gösterir', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _approver,
      offerResponses: [(status: 200, body: _offer()), (status: 200, body: _offer(passive: true))],
      toggle: [(status: 200, body: {'ok': true})],
    );
    expect(find.byKey(const ValueKey('offer-passive-notice')), findsNothing);

    await _openMenu(tester);
    await tester.tap(find.text('Arşivle'));
    await tester.pumpAndSettle();
    expect(find.textContaining('arşive alınsın mı'), findsOneWidget);
    expect(adapter.calls, isNot(contains('/offers/o1/toggle-passive')), reason: 'onaydan önce istek yok');

    await tester.tap(find.byKey(const ValueKey('offer-passive-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/toggle-passive'), {'is_passive': true});
    expect(find.text('TKF-001 arşivlendi'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-passive-notice')), findsOneWidget);
    // Arşivdeki teklifte paylaşım/e-posta yok, menü artık geri almayı sunar.
    expect(find.text('Paylaşım Linki'), findsNothing);
    await _openMenu(tester);
    expect(find.text('Arşivden Çıkar'), findsOneWidget);
  });

  testWidgets('arşivdeki teklif "Arşivden Çıkar" ile is_passive:false gönderir', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _approver,
      offerResponses: [(status: 200, body: _offer(passive: true)), (status: 200, body: _offer())],
      toggle: [(status: 200, body: {'ok': true})],
    );
    expect(find.textContaining('"Arşivden Çıkar"ı kullan'), findsOneWidget);

    await _openMenu(tester);
    await tester.tap(find.text('Arşivden Çıkar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('offer-passive-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/toggle-passive'), {'is_passive': false});
    expect(find.text('TKF-001 arşivden çıkarıldı'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-passive-notice')), findsNothing);
  });

  testWidgets('Vazgeç istek atmaz', (tester) async {
    final adapter = await _pump(tester, permissions: _approver, offerResponses: [(status: 200, body: _offer())]);

    await _openMenu(tester);
    await tester.tap(find.text('Arşivle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/o1/toggle-passive')));
  });

  testWidgets('offers.approve yoksa arşiv seçeneği yok (silme izni varsa menüde yalnızca Sil)', (tester) async {
    await _pump(
      tester,
      permissions: {'offers.read', 'offers.update', 'offers.delete'},
      offerResponses: [(status: 200, body: _offer())],
    );
    await _openMenu(tester);
    expect(find.text('Teklifi Sil'), findsOneWidget);
    expect(find.text('Arşivle'), findsNothing);
  });

  testWidgets('offers.approve yoksa arşiv notu geri alma yolunu önermez', (tester) async {
    await _pump(tester, permissions: {'offers.read'}, offerResponses: [(status: 200, body: _offer(passive: true))]);
    expect(find.byKey(const ValueKey('offer-passive-notice')), findsOneWidget);
    expect(find.textContaining('Arşivden Çıkar'), findsNothing);
    expect(find.byTooltip('Diğer işlemler'), findsNothing);
  });
}

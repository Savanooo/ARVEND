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

/// Teklif silme talebi (backend migration 0067): silme izni olmayan kişi
/// menüden talep açar; silme yetkilisi detaydaki uyarıdan onaylar ya da
/// reddeder; talebi açan geri çekebilir.

Map<String, dynamic> _offer({Map<String, dynamic>? deleteRequest}) => {
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
      'is_passive': false,
      'items': <Object>[],
      'delete_request': ?deleteRequest,
    };

Map<String, dynamic> _request({String requestedBy = 'u2'}) => {
      'id': 'r1',
      'offer_id': 'o1',
      'requested_by': requestedBy,
      'requested_by_name': 'Satış Personeli',
      'reason': 'yanlış müşteri',
      'created_at': '2026-10-14T09:30:00Z',
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required Set<String> permissions,
  required List<ScriptedResponse> offerResponses,
  Map<String, List<ScriptedResponse>> extra = const {},
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/offers/o1': offerResponses,
    '/offers/o1/revisions': [for (var i = 0; i < 4; i++) (status: 200, body: {'revisions': <Object>[]})],
    '/offers/o1/share-links': [for (var i = 0; i < 4; i++) (status: 200, body: {'share_links': <Object>[]})],
    ...extra,
  });
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: '/teklifler/o1',
    routes: [
      GoRoute(path: '/teklifler', builder: (c, s) => const Scaffold(body: Text('TEKLİF LİSTESİ'))),
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

const _editor = {'offers.read', 'offers.create', 'offers.update'};
const _approver = {'offers.read', 'offers.update', 'offers.delete'};

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('silme izni olmayan menüden gerekçeyle talep gönderir', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _editor,
      offerResponses: [
        (status: 200, body: _offer()),
        (status: 200, body: _offer(deleteRequest: _request(requestedBy: 'u1'))),
      ],
      extra: {
        '/offers/o1/delete-request': [(status: 201, body: _request(requestedBy: 'u1'))],
      },
    );
    await tester.tap(find.byTooltip('Diğer işlemler'));
    await tester.pumpAndSettle();
    expect(find.text('Teklifi Sil'), findsNothing, reason: 'direkt silme yalnızca offers.delete ile');
    await tester.tap(find.text('Silme Talebi Gönder'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('offer-delete-request-reason')), 'yanlış müşteri');
    await tester.tap(find.byKey(const ValueKey('offer-delete-request-reason-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/delete-request'), {'reason': 'yanlış müşteri'});
    expect(find.textContaining('Silme talebi gönderildi'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-delete-request-notice')), findsOneWidget);
    // Kendi talebini geri çekebilir, karar veremez.
    expect(find.byKey(const ValueKey('offer-delete-withdraw')), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-delete-approve')), findsNothing);
    // Bekleyen talep varken yeni talep sunulmaz (başka seçenek de yoksa menü
    // hiç görünmez).
    expect(find.byTooltip('Diğer işlemler'), findsNothing);
  });

  testWidgets('silme yetkilisi bekleyen talebi onaylar: teklif silinir, listeye döner', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _approver,
      offerResponses: [(status: 200, body: _offer(deleteRequest: _request()))],
      extra: {
        '/offers/o1/delete-request/approve': [(status: 200, body: {'ok': true})],
      },
    );
    expect(find.textContaining('Satış Personeli bu teklifin silinmesini istedi'), findsOneWidget);
    expect(find.textContaining('Neden: yanlış müşteri'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-delete-withdraw')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('offer-delete-approve')));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/o1/delete-request/approve')), reason: 'onaydan önce istek yok');
    await tester.tap(find.byKey(const ValueKey('offer-delete-approve-confirm')));
    await tester.pumpAndSettle();

    expect(adapter.calls, contains('/offers/o1/delete-request/approve'));
    expect(find.text('TEKLİF LİSTESİ'), findsOneWidget);
  });

  testWidgets('silme yetkilisi gerekçeyle reddeder: teklif kalır', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _approver,
      offerResponses: [
        (status: 200, body: _offer(deleteRequest: _request())),
        (status: 200, body: _offer()),
      ],
      extra: {
        '/offers/o1/delete-request/reject': [(status: 200, body: {'ok': true})],
      },
    );
    await tester.tap(find.byKey(const ValueKey('offer-delete-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('offer-delete-reject-note')), 'müşteri düşünüyor');
    await tester.tap(find.byKey(const ValueKey('offer-delete-reject-note-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/delete-request/reject'), {'note': 'müşteri düşünüyor'});
    expect(find.text('Silme talebi reddedildi'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-delete-request-notice')), findsNothing);
  });

  testWidgets('başkasının talebini gören silme izinsiz kişi yalnızca uyarıyı görür', (tester) async {
    await _pump(
      tester,
      permissions: _editor,
      offerResponses: [(status: 200, body: _offer(deleteRequest: _request(requestedBy: 'u2')))],
    );
    expect(find.byKey(const ValueKey('offer-delete-request-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-delete-withdraw')), findsNothing);
    expect(find.byKey(const ValueKey('offer-delete-approve')), findsNothing);
    expect(find.byKey(const ValueKey('offer-delete-reject')), findsNothing);
  });
}

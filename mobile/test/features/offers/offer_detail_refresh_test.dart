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

/// E-posta gönderimi taslağı "gönderildi" yapar, yeni bir paylaşım linki
/// oluşturur ve önceki revizyonların linklerini iptal eder; "Gönderildi"
/// işareti de linkleri iptal eder. Eskiden "Paylaşım Linkleri" ve revizyon
/// listesi ancak aşağı çekip yenileyince doğru görünüyordu.

const _perms = {'offers.read', 'offers.update', 'offers.approve'};

Map<String, dynamic> _offer(String status) => {
      'id': 'o1',
      'offer_no': 'TKF-001',
      'revision_no': 1,
      'customer_name': 'Ali Veli',
      'customer_email': 'ali@example.com',
      'offer_date': '2026-09-20',
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': status,
      'is_passive': false,
      'items': <Object>[],
    };

Map<String, dynamic> _revisions(String currentStatus) => {
      'revisions': [
        {'id': 'r0', 'offer_id': 'o1', 'revision_no': 0, 'status': 'reddedildi', 'grand_total': 1000},
        {'id': 'r1', 'offer_id': 'o1', 'revision_no': 1, 'status': currentStatus, 'grand_total': 1200},
      ],
    };

Map<String, dynamic> _link(String id, {required bool active}) => {
      'id': id,
      'offer_id': 'o1',
      'revision_id': id == 'old' ? 'r0' : 'r1',
      'token': 'tok-$id',
      'created_at': '2026-10-01T10:00:00Z',
      'revoked_at': active ? null : '2026-10-11T10:00:00Z',
      'is_active': active,
    };

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter) async {
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
        authControllerProvider.overrideWith(() => FakeAuth(testUser(_perms))),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.widgetWithText(ElevatedButton, label).evaluate().isNotEmpty
      ? find.widgetWithText(ElevatedButton, label)
      : find.widgetWithText(OutlinedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

final _revisionList = find.text('Revizyon #1 (güncel)');

/// Revizyon listesindeki güncel revizyon satırının durum rozeti.
Finder _currentRevisionStatus(String label) => find.descendant(
      of: find.ancestor(of: _revisionList, matching: find.byType(Row)).first,
      matching: find.text(label),
    );

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('e-posta gönderimi sonrası paylaşım linkleri ve revizyon listesi tazelenir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak')), (status: 200, body: _offer('gönderildi'))],
      // Revizyonları geçmiş bölümü de okur: açılışta iki, tazelemede iki istek.
      '/offers/o1/revisions': [
        (status: 200, body: _revisions('taslak')),
        (status: 200, body: _revisions('taslak')),
        (status: 200, body: _revisions('gönderildi')),
        (status: 200, body: _revisions('gönderildi')),
      ],
      '/offers/o1/share-links': [
        (status: 200, body: {'share_links': [_link('old', active: true)]}),
        (status: 200, body: {'share_links': [_link('new', active: true), _link('old', active: false)]}),
      ],
      '/offers/o1/send-email': [(status: 200, body: {'ok': true})],
    });
    await _pump(tester, adapter);
    expect(find.text('Eski linkler (1)'), findsNothing);
    expect(_currentRevisionStatus('Taslak'), findsOneWidget);

    await _tap(tester, 'E-posta Gönder');
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(adapter.calls.where((c) => c == '/offers/o1/share-links').length, 2);
    // Eski revizyonun linki artık "Eski linkler" altında, yenisi aktif.
    expect(find.text('Eski linkler (1)'), findsOneWidget);
    expect(find.textContaining('tok-new'), findsOneWidget);
    expect(_currentRevisionStatus('Gönderildi'), findsOneWidget);
  });

  testWidgets('"Gönderildi" işaretlenince paylaşım linkleri tazelenir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak')), (status: 200, body: _offer('gönderildi'))],
      '/offers/o1/revisions': [
        (status: 200, body: _revisions('taslak')),
        (status: 200, body: _revisions('taslak')),
        (status: 200, body: _revisions('gönderildi')),
        (status: 200, body: _revisions('gönderildi')),
      ],
      '/offers/o1/share-links': [
        (status: 200, body: {'share_links': [_link('old', active: true)]}),
        (status: 200, body: {'share_links': [_link('old', active: false)]}),
      ],
      '/offers/o1/status': [(status: 200, body: _offer('gönderildi'))],
    });
    await _pump(tester, adapter);

    await _tap(tester, 'Gönderildi Olarak İşaretle');
    await tester.tap(find.byKey(const ValueKey('offer-status-confirm')));
    await tester.pumpAndSettle();

    expect(adapter.calls.where((c) => c == '/offers/o1/share-links').length, 2);
    expect(find.text('Aktif link yok'), findsOneWidget);
  });
}

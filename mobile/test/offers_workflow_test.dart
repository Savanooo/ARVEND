import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/offers/data/offers_repository.dart';
import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import 'test_utils/fake_api_client.dart';

Map<String, dynamic> _meJson({List<String> permissions = const []}) => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Test Kullanıcı',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    };

Map<String, dynamic> _offerJson({
  String id = 'o1',
  String status = 'kabul edildi',
  bool isPassive = false,
}) =>
    {
      'id': id,
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_id': 'c1',
      'customer_name': 'Ali Veli',
      'customer_phone': '',
      'customer_email': '',
      'customer_address': '',
      'offer_date': '2026-09-20',
      'valid_until': null,
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': status,
      'is_passive': isPassive,
      'items': <Map<String, dynamic>>[],
    };

GoRouter _buildDetailTestRouter(String offerId) => GoRouter(
      initialLocation: '/teklifler/$offerId',
      routes: [
        GoRoute(path: '/teklifler/:id', builder: (c, s) => OfferDetailScreen(offerId: s.pathParameters['id']!)),
        GoRoute(path: '/teklifler/:id/duzenle', builder: (c, s) => const Scaffold(body: Text('Düzenle ekranı'))),
        GoRoute(path: '/projeler', builder: (c, s) => const Scaffold(body: Text('Proje Listesi'))),
        GoRoute(path: '/teklifler', builder: (c, s) => const Scaffold(body: Text('Teklif Listesi'))),
        GoRoute(
          path: '/projeler/:id',
          builder: (c, s) => Scaffold(body: Text('Proje: ${s.pathParameters['id']}')),
        ),
      ],
    );

Map<String, dynamic> _linkJson({
  String id = 'l1',
  String token = 'tok-abc',
  bool active = true,
  String? revokedAt,
}) =>
    {
      'id': id,
      'offer_id': 'o1',
      'revision_id': 'r1',
      'token': token,
      'created_at': '2026-09-20T10:00:00Z',
      'expires_at': null,
      'revoked_at': revokedAt,
      'is_active': active,
    };

Future<void> _pumpDetail(WidgetTester tester, FakeHttpClientAdapter adapter, String offerId) async {
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp.router(routerConfig: _buildDetailTestRouter(offerId)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('ShareLink.fromJson', () {
    test('parses the full backend field set', () {
      final link = ShareLink.fromJson({
        'id': 'l1',
        'offer_id': 'o1',
        'revision_id': 'r1',
        'token': 'tok123',
        'created_by': 'u1',
        'created_at': '2026-09-20T10:00:00Z',
        'expires_at': null,
        'revoked_at': null,
        'is_active': true,
      });
      expect(link.id, 'l1');
      expect(link.revisionId, 'r1');
      expect(link.token, 'tok123');
      expect(link.isActive, isTrue);
      expect(link.expiresAt, isNull);
      expect(link.revokedAt, isNull);
    });

    test('a revoked/expired link parses is_active=false', () {
      final link = ShareLink.fromJson({
        'id': 'l1', 'offer_id': 'o1', 'revision_id': 'r1', 'token': 'tok',
        'created_at': '2026-09-20T10:00:00Z', 'revoked_at': '2026-09-21T10:00:00Z', 'is_active': false,
      });
      expect(link.isActive, isFalse);
      expect(link.revokedAt, '2026-09-21T10:00:00Z');
    });
  });

  group('OffersRepository — share links', () {
    test('createShareLink POSTs expires_in (default unbounded) and parses the token', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/share-links': [
          (
            status: 201,
            body: {
              'id': 'l1', 'offer_id': 'o1', 'revision_id': 'r1', 'token': 'abc',
              'created_at': '2026-09-20T10:00:00Z', 'is_active': true,
            },
          ),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      final link = await repo.createShareLink('o1');

      expect(link.token, 'abc');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['expires_in'], '');
      // Backend bilinmeyen alanı reddeder: mark_sent'i tanımayan sunucuda
      // varsayılan istek bozulmasın diye alan hiç gönderilmez.
      expect(body.containsKey('mark_sent'), isFalse);
    });

    test('createShareLink(markSent: true) sends mark_sent', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/share-links': [
          (
            status: 201,
            body: {
              'id': 'l1', 'offer_id': 'o1', 'revision_id': 'r1', 'token': 'abc',
              'created_at': '2026-09-20T10:00:00Z', 'is_active': true,
            },
          ),
        ],
      });
      final repo = OffersRepository(await buildFakeApiClient(adapter));

      await repo.createShareLink('o1', markSent: true);

      expect(adapter.requestBodies.single, {'expires_in': '', 'mark_sent': true});
    });

    test('shareLinks() unwraps the share_links array', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/share-links': [
          (
            status: 200,
            body: {
              'share_links': [
                {
                  'id': 'l1', 'offer_id': 'o1', 'revision_id': 'r1', 'token': 'abc',
                  'created_at': '2026-09-20T10:00:00Z', 'is_active': true,
                },
              ],
            },
          ),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      final links = await repo.shareLinks('o1');

      expect(links, hasLength(1));
      expect(links.single.token, 'abc');
    });

    test('revokeShareLink DELETEs the exact link path', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/share-links/l1': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      await repo.revokeShareLink('o1', 'l1');

      expect(adapter.calls, ['/offers/o1/share-links/l1']);
    });
  });

  group('OffersRepository — sendEmail', () {
    test('empty to/subject/message by default -- backend applies its own template', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/send-email': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      await repo.sendEmail('o1');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['to'], '');
      expect(body['subject'], '');
      expect(body['message'], '');
    });

    test('an explicit recipient overrides the backend default', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/send-email': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      await repo.sendEmail('o1', to: 'ali@example.com');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['to'], 'ali@example.com');
    });

    test('backend rejection (e.g. no recipient on file) surfaces as ApiException', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/send-email': [(status: 400, body: {'error': 'alıcı e-posta adresi belirtilmedi'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      await expectLater(
        repo.sendEmail('o1'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'alıcı e-posta adresi belirtilmedi')),
      );
    });
  });

  group('OffersRepository — linkedProjectId', () {
    test('200 returns the linked project id', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/project': [(status: 200, body: {'id': 'p1', 'project_no': 'PRJ-1'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      expect(await repo.linkedProjectId('o1'), 'p1');
    });

    test('404 (not yet converted) returns null, not an error', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/project': [(status: 404, body: {'error': 'kayıt bulunamadı'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      expect(await repo.linkedProjectId('o1'), isNull);
    });
  });

  group('offerLinkedProjectIdProvider', () {
    test('fetches through the repository and reflects invalidation after conversion', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/project': [
          (status: 404, body: {'error': 'kayıt bulunamadı'}),
          (status: 200, body: {'id': 'p1'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      expect(await container.read(offerLinkedProjectIdProvider('o1').future), isNull);

      container.invalidate(offerLinkedProjectIdProvider('o1'));
      expect(await container.read(offerLinkedProjectIdProvider('o1').future), 'p1');
    });
  });

  group('OffersRepository — create/update item integrity', () {
    test('section_label per item and top-level customer_id both flow through create', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/': [(status: 201, body: _offerJson())],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      await repo.create(
        customerId: 'c1',
        customerName: 'Ali Veli',
        items: const [
          OfferItem(
            id: '',
            productId: null,
            productName: 'Sıva',
            quantity: 10,
            unitPrice: 50,
            lineTotal: 0,
            unit: 'm2',
            sectionLabel: 'Salon',
            calcCategoryId: null,
            calcSnapshot: null,
          ),
        ],
      );

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['customer_id'], 'c1');
      final items = body['items'] as List;
      expect((items.single as Map)['section_label'], 'Salon');
      expect((items.single as Map)['product_name'], 'Sıva');
    });
  });

  group('OfferCreateScreen — customer picker', () {
    testWidgets('picking an existing customer fills name/phone/email/address', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/customers': [
          (
            status: 200,
            body: {
              'customers': [
                {
                  'id': 'c1', 'name': 'Ali Veli', 'phone': '5551112233', 'email': 'ali@x.com',
                  'address': 'Adres 1', 'tax_office': '', 'tax_number': '', 'notes': '', 'is_active': true,
                },
              ],
            },
          ),
        ],
      });
      final client = await buildFakeApiClient(adapter);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: OfferCreateScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Seç'));
      await tester.pumpAndSettle();
      expect(find.text('Ali Veli'), findsOneWidget);

      await tester.tap(find.text('Ali Veli'));
      await tester.pumpAndSettle();

      expect(find.text('Ali Veli'), findsOneWidget);
      expect(find.text('5551112233'), findsOneWidget);
      expect(find.text('ali@x.com'), findsOneWidget);
      expect(find.text('Adres 1'), findsOneWidget);
    });

    testWidgets('section label field is editable per item', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {'/auth/me': [(status: 200, body: _meJson())]});
      final client = await buildFakeApiClient(adapter);

      // Formdaki birden çok TextFormField kendi iç kaydırılabilirini
      // taşıyabildiği için (imleç takibi) `scrollUntilVisible`'ın
      // varsayılan Scrollable bulucusu belirsiz olur -- bunun yerine
      // her şeyin kaydırmadan sığdığı bir test yüzeyi kullanılır.
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: OfferCreateScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final sectionField = find.widgetWithText(TextFormField, 'Bölüm / Alan (opsiyonel — Salon, Oda 1, Koridor...)');
      expect(sectionField, findsOneWidget);

      await tester.enterText(sectionField, 'Oda 1');
      await tester.pump();

      expect(find.text('Oda 1'), findsOneWidget);
    });
  });

  group('OfferDetailScreen — convert-to-project permission gate + duplicate protection', () {
    testWidgets('no projects.create permission -> no convert/view-project button at all', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'kabul edildi'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
      });
      await _pumpDetail(tester, adapter, 'o1');

      expect(find.text('Projeye Dönüştür'), findsNothing);
      expect(find.text('Projeyi Görüntüle'), findsNothing);
      // İzin yoksa /offers/o1/project'e hiç istek atılmamalı.
      expect(adapter.calls, isNot(contains('/offers/o1/project')));
    });

    testWidgets('has permission, not yet converted -> shows Projeye Dönüştür, tap navigates to the new project',
        (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.create']))],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'kabul edildi'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        '/offers/o1/project': [
          (status: 404, body: {'error': 'kayıt bulunamadı'}),
          (status: 200, body: {'id': 'p1', 'project_no': 'PRJ-1'}),
        ],
        '/projects/from-offer/o1': [(status: 201, body: {'id': 'p1', 'project_no': 'PRJ-1'})],
      });
      await _pumpDetail(tester, adapter, 'o1');
      await tester.scrollUntilVisible(find.text('Projeye Dönüştür'), 300);

      expect(find.text('Projeye Dönüştür'), findsOneWidget);
      expect(find.text('Projeyi Görüntüle'), findsNothing);

      await tester.tap(find.text('Projeye Dönüştür'));
      await tester.pumpAndSettle();

      // Web'deki gibi önce form: ad "Müşteri - TeklifNo" ile dolu gelir,
      // istek ancak "Projeyi Oluştur" ile atılır.
      expect(adapter.calls, isNot(contains('/projects/from-offer/o1')));
      final name = tester.widget<TextField>(find.byKey(const Key('convert-name')));
      expect(name.controller!.text, 'Ali Veli - TKF-001');
      await tester.enterText(find.byKey(const Key('convert-name')), 'Ali Veli Villa');
      await tester.tap(find.text('Projeyi Oluştur'));
      await tester.pumpAndSettle();

      final body = adapter.requestBodies[adapter.calls.indexOf('/projects/from-offer/o1')] as Map;
      expect(body['name'], 'Ali Veli Villa');
      expect(body['start_date'], isNull);
      expect(find.text('Proje: p1'), findsOneWidget);
    });

    testWidgets('has permission, already converted -> shows Projeyi Görüntüle, tap navigates straight there',
        (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.create']))],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'kabul edildi'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        '/offers/o1/project': [(status: 200, body: {'id': 'p1', 'project_no': 'PRJ-1'})],
      });
      await _pumpDetail(tester, adapter, 'o1');
      await tester.scrollUntilVisible(find.text('Projeyi Görüntüle'), 300);

      expect(find.text('Projeyi Görüntüle'), findsOneWidget);
      expect(find.text('Projeye Dönüştür'), findsNothing);

      await tester.tap(find.text('Projeyi Görüntüle'));
      await tester.pumpAndSettle();

      expect(find.text('Proje: p1'), findsOneWidget);
      // Zaten dönüştürülmüş bir teklif için ikinci bir POST /projects/from-offer
      // ASLA atılmamalı -- yinelenen proje oluşturma koruması.
      expect(adapter.calls, isNot(contains('/projects/from-offer/o1')));
    });

    testWidgets('offer not accepted -> no convert button even with permission', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.create']))],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'taslak'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
      });
      await _pumpDetail(tester, adapter, 'o1');

      expect(find.text('Projeye Dönüştür'), findsNothing);
      expect(find.text('Projeyi Görüntüle'), findsNothing);
    });
  });

  group('OfferDetailScreen — share link + send email actions', () {
    // Gönderilmiş teklif: soru yok, durum dokunulmaz (taslak akışı için bkz.
    // test/features/offers/offer_share_link_draft_test.dart).
    testWidgets('creating a share link shows a copyable URL built from the token', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'gönderildi'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        // Sahte adaptör yolu sırayla tüketir: açılışta liste (boş), sonra
        // oluşturma, sonra oluşturmanın tetiklediği liste tazelemesi.
        '/offers/o1/share-links': [
          (status: 200, body: {'share_links': <dynamic>[]}),
          (status: 201, body: _linkJson()),
          (status: 200, body: {'share_links': [_linkJson()]}),
        ],
      });
      await _pumpDetail(tester, adapter, 'o1');
      expect(find.text('Paylaşım Linkleri'), findsNothing, reason: 'hiç link yokken bölüm görünmez');
      await tester.scrollUntilVisible(find.text('Paylaşım Linki'), 300);
      // İzinsiz kullanıcıda durum düğmeleri yok, sayfa kısa: düğme ilk
      // karede önbellek bölgesinde kurulur ama ekranın altında kalır.
      await tester.ensureVisible(find.text('Paylaşım Linki'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Paylaşım Linki'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('${AppConfig.apiBaseUrl}/paylas/tok-abc')),
          findsOneWidget);
      expect(find.text('Teklif taslak'), findsNothing);
      final post = adapter.requestBodies[adapter.methods.indexOf('POST')] as Map<String, dynamic>;
      expect(post.containsKey('mark_sent'), isFalse);
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();
      expect(find.text('Paylaşım Linkleri', skipOffstage: false), findsOneWidget, reason: 'yeni link listede');
    });

    testWidgets('an active share link can be revoked after confirmation (offers.update)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['offers.read', 'offers.update']))],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'gönderildi'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        '/offers/o1/share-links': [
          (
            status: 200,
            body: {
              'share_links': [
                _linkJson(),
                _linkJson(id: 'l0', token: 'eski', active: false, revokedAt: '2026-09-19T08:00:00Z'),
              ],
            },
          ),
          (status: 200, body: {'share_links': [_linkJson(active: false, revokedAt: '2026-09-21T08:00:00Z')]}),
        ],
        '/offers/o1/share-links/l1': [(status: 200, body: {'ok': true})],
      });
      await _pumpDetail(tester, adapter, 'o1');
      await tester.scrollUntilVisible(find.text('İptal Et'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Eski linkler (1)'), findsOneWidget);

      await tester.ensureVisible(find.text('İptal Et'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      expect(adapter.calls, isNot(contains('/offers/o1/share-links/l1')), reason: 'onaydan önce istek yok');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('İptal Et')));
      await tester.pumpAndSettle();

      expect(adapter.calls, contains('/offers/o1/share-links/l1'));
      expect(find.text('Aktif link yok'), findsOneWidget);
    });

    testWidgets('without offers.update there is no revoke button', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['offers.read']))],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'gönderildi'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        '/offers/o1/share-links': [
          (status: 200, body: {'share_links': [_linkJson()]}),
        ],
      });
      await _pumpDetail(tester, adapter, 'o1');
      await tester.scrollUntilVisible(find.text('Kopyala'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('İptal Et'), findsNothing);
    });

    testWidgets('send email prompts for confirmation, then posts and shows success', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/o1': [
          (status: 200, body: _offerJson(status: 'taslak')),
          (status: 200, body: _offerJson(status: 'gönderildi')),
        ],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        '/offers/o1/send-email': [(status: 200, body: {'ok': true})],
      });
      await _pumpDetail(tester, adapter, 'o1');
      await tester.scrollUntilVisible(find.text('E-posta Gönder'), 300);

      await tester.tap(find.text('E-posta Gönder'));
      await tester.pumpAndSettle();
      // Onay diyaloğu gösterilene kadar POST atılmamalı.
      expect(adapter.calls, isNot(contains('/offers/o1/send-email')));

      await tester.tap(find.text('Gönder'));
      await tester.pumpAndSettle();

      expect(adapter.calls, contains('/offers/o1/send-email'));
      expect(find.text('E-posta gönderildi'), findsOneWidget);
    });

    testWidgets('cancelling the send-email confirmation sends nothing', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'taslak'))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
      });
      await _pumpDetail(tester, adapter, 'o1');
      await tester.scrollUntilVisible(find.text('E-posta Gönder'), 300);

      await tester.tap(find.text('E-posta Gönder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();

      expect(adapter.calls, isNot(contains('/offers/o1/send-email')));
    });

    testWidgets('passive (archived) offers hide share-link/email actions', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/o1': [(status: 200, body: _offerJson(status: 'taslak', isPassive: true))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
      });
      await _pumpDetail(tester, adapter, 'o1');

      expect(find.text('Paylaşım Linki'), findsNothing);
      expect(find.text('E-posta Gönder'), findsNothing);
    });
  });

  group('OfferDetailScreen — delete', () {
    testWidgets('offers.delete: menu deletes after confirmation and returns to the list', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['offers.read', 'offers.delete']))],
        '/offers/o1': [
          (status: 200, body: _offerJson(status: 'taslak')),
          (status: 200, body: {'ok': true}),
        ],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
        '/offers/o1/share-links': [(status: 200, body: {'share_links': <dynamic>[]})],
      });
      await _pumpDetail(tester, adapter, 'o1');

      await tester.tap(find.byTooltip('Diğer işlemler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Teklifi Sil'));
      await tester.pumpAndSettle();
      expect(find.textContaining('silinsin mi'), findsOneWidget);
      expect(adapter.calls.where((c) => c == '/offers/o1').length, 1, reason: 'onaydan önce DELETE yok');

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Sil')));
      await tester.pumpAndSettle();

      expect(adapter.calls.where((c) => c == '/offers/o1').length, 2, reason: 'DELETE /offers/o1');
      expect(find.text('Teklif Listesi'), findsOneWidget);
    });

    testWidgets('accepted offers and users without offers.delete get no delete option', (tester) async {
      for (final (status, perms) in [
        ('kabul edildi', ['offers.read', 'offers.delete']),
        ('taslak', ['offers.read']),
      ]) {
        final adapter = FakeHttpClientAdapter(script: {
          '/auth/me': [(status: 200, body: _meJson(permissions: perms))],
          '/offers/o1': [(status: 200, body: _offerJson(status: status))],
          '/offers/o1/revisions': [(status: 200, body: {'revisions': <dynamic>[]})],
          '/offers/o1/share-links': [(status: 200, body: {'share_links': <dynamic>[]})],
        });
        await _pumpDetail(tester, adapter, 'o1');
        expect(find.byTooltip('Diğer işlemler'), findsNothing, reason: '$status / $perms');
      }
    });
  });
}

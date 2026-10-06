import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/offers/data/offers_repository.dart';
import 'package:arvend/features/offers/presentation/offers_screen.dart';

import 'test_utils/fake_api_client.dart';

Map<String, dynamic> _offerJson(String id, {String status = 'taslak'}) => {
      'id': id,
      'offer_no': 'TKF-$id',
      'revision_no': 0,
      'customer_id': null,
      'customer_name': 'Müşteri $id',
      'customer_phone': '',
      'customer_email': '',
      'customer_address': '',
      'offer_date': '2026-09-01',
      'valid_until': null,
      'subtotal': 100,
      'vat_rate': 20,
      'vat_amount': 20,
      'grand_total': 120,
      'notes': '',
      'status': status,
      'is_passive': false,
      'items': <dynamic>[],
    };

Map<String, dynamic> _meJson() => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Test',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': <String>[],
    };

/// Teklif listesi artık sunucu tarafı filtre + gerçek sayfalama ile
/// çalışıyor -- eskiden ilk 50 satırdan sonrası hiç görünmüyordu.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  test('OffersRepository.page durum/arama/sayfa parametrelerini gönderir ve sayaçları okur', () async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/': [
        (
          status: 200,
          body: {
            'offers': [_offerJson('1', status: 'gönderildi')],
            'total': 73,
            'status_counts': {'taslak': 10, 'gönderildi': 73, 'kabul edildi': 2, 'reddedildi': 0},
          },
        ),
      ],
    });
    final repo = OffersRepository(await buildFakeApiClient(adapter));

    final page = await repo.page(passive: true, status: 'gönderildi', q: 'ali', page: 2);

    final query = adapter.requestQueries.single;
    expect(query['filter'], 'pasif');
    expect(query['status'], 'gönderildi');
    expect(query['q'], 'ali');
    expect(query['page'], 2);
    expect(query['limit'], OfferListPage.pageSize);
    expect(page.total, 73);
    expect(page.statusCounts['gönderildi'], 73);
    expect(page.offers.single.id, '1');
  });

  test('boş filtreler gönderilmez', () async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
    });
    final repo = OffersRepository(await buildFakeApiClient(adapter));
    final page = await repo.page();
    final query = adapter.requestQueries.single;
    expect(query.containsKey('filter'), isFalse);
    expect(query.containsKey('status'), isFalse);
    expect(query.containsKey('q'), isFalse);
    expect(page.statusCounts, isEmpty);
  });

  test('offersPagedProvider sonraki sayfayı ekler, tekrarları atar, sonda durur', () async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/': [
        (status: 200, body: {'offers': [_offerJson('1'), _offerJson('2')], 'total': 3}),
        // Sayfa kayması: '2' tekrar gelir, '3' yenidir.
        (status: 200, body: {'offers': [_offerJson('2'), _offerJson('3')], 'total': 3}),
      ],
    });
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(await buildFakeApiClient(adapter))],
    );
    addTearDown(container.dispose);
    const query = (passive: false, status: '', q: '');
    final sub = container.listen(offersPagedProvider(query), (_, _) {});
    addTearDown(sub.close);

    final first = await container.read(offersPagedProvider(query).future);
    expect(first.offers.map((o) => o.id), ['1', '2']);
    expect(first.hasMore, isTrue);

    await container.read(offersPagedProvider(query).notifier).loadMore();
    final after = container.read(offersPagedProvider(query)).requireValue;
    expect(after.offers.map((o) => o.id), ['1', '2', '3']);
    expect(after.hasMore, isFalse);
    expect(adapter.requestQueries.last['page'], 2);
  });

  testWidgets('OffersScreen: "Daha fazla göster" ikinci sayfayı yükler, aramayı sunucuya gönderir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meJson())],
      '/offers/': [
        (status: 200, body: {'offers': [_offerJson('1')], 'total': 2}),
        (status: 200, body: {'offers': [_offerJson('2')], 'total': 2}),
        (status: 200, body: {'offers': [_offerJson('9')], 'total': 1}),
      ],
    });
    final client = await buildFakeApiClient(adapter);
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const MaterialApp(home: OffersScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2 teklif'), findsOneWidget);
    expect(find.text('TKF-1'), findsOneWidget);
    await tester.tap(find.text('Daha fazla göster (1 / 2)'));
    await tester.pumpAndSettle();
    expect(find.text('TKF-2'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Müşteri 9');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(adapter.requestQueries.last['q'], 'Müşteri 9');
    expect(find.text('TKF-9'), findsOneWidget);
    expect(find.text('TKF-1'), findsNothing);
  });
}

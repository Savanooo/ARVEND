import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/products/data/products_repository.dart';
import 'package:arvend/features/products/domain/price_change.dart';
import 'package:arvend/features/products/domain/price_source.dart';
import 'package:arvend/features/products/domain/product.dart';

import '../../test_utils/fake_api_client.dart';
import 'products_fakes.dart';

/// Depo <-> backend sözleşmesi: gerçek ApiClient + betikli sahte HTTP
/// adaptörü (ağ yok). Yollar, sorgu parametreleri ve gövdeler backend
/// router.go / handler'larıyla BİREBİR olmalı.
void main() {
  Future<(ProductsRepository, FakeHttpClientAdapter)> repoWith(Map<String, List<ScriptedResponse>> script) async {
    final adapter = FakeHttpClientAdapter(script: script);
    return (ProductsRepository(await buildFakeApiClient(adapter)), adapter);
  }

  test('list: sayfa + limit (<=200) + arama', () async {
    final (repo, adapter) = await repoWith({
      '/products': [
        (status: 200, body: {'products': catalogJson(), 'total': 628}),
      ],
    });
    final page = await repo.list(q: 'boya', page: 3);
    expect(page.total, 628);
    expect(page.products.first.sourcePrice, 100);
    expect(adapter.requestQueries.single, {'page': '3', 'limit': '$kProductsPageSize', 'q': 'boya'});
    expect(kProductsPageSize, lessThanOrEqualTo(200));
  });

  test('create/update: yalnızca backend alanları', () async {
    final (repo, adapter) = await repoWith({
      '/products': [(status: 201, body: productJson(id: 'n', name: 'Yeni'))],
      '/products/p1': [(status: 200, body: productJson(id: 'p1', name: 'Kutu'))],
    });
    const input = ProductInput(name: 'Yeni', unit: 'm', unitPrice: 1250.5, category: 'Profil', description: 'açıklama');
    await repo.create(input);
    await repo.update('p1', input);
    final expected = {'name': 'Yeni', 'unit': 'm', 'unit_price': 1250.5, 'description': 'açıklama', 'category': 'Profil'};
    expect(adapter.requestBodies, [expected, expected]);
    expect(adapter.calls, ['/products', '/products/p1']);
  });

  test('price-history ve price-sources', () async {
    final (repo, _) = await repoWith({
      '/products/p1/price-history': [
        (status: 200, body: {'history': historyJson()}),
      ],
      '/products/price-sources': [
        (status: 200, body: {'sources': [ulasSourceJson(), demirSourceJson()]}),
      ],
    });
    final history = await repo.priceHistory('p1');
    expect(history.map((h) => h.reason), ['supplier', 'markup', 'manual']);
    expect(history.last.source, isNull);
    final sources = await repo.priceSources();
    expect(sources.map((s) => s.source), [kUlasSource, kDemirProfilSource]);
  });

  test('sync: POST yolu; 409 çakışma ApiException olarak gelir', () async {
    final (repo, adapter) = await repoWith({
      '/products/price-sources/ulas/sync': [
        (status: 200, body: {
          'source': 'ulas', 'total': 1, 'created': 1, 'updated': 0, 'unchanged': 0, 'missing': 0,
          'synced_at': kUlasSyncedAt, 'list_label': '',
        }),
        (status: 409, body: {'error': 'bu fiyat kaynağı için şu anda başka bir senkron çalışıyor, biraz sonra tekrar deneyin'}),
      ],
    });
    final res = await repo.syncPriceSource('ulas');
    expect(res.counts.created, 1);
    await expectLater(
      repo.syncPriceSource('ulas'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );
    expect(adapter.calls, ['/products/price-sources/ulas/sync', '/products/price-sources/ulas/sync']);
  });

  test('updatePriceSource: PUT tam durum gövdesi', () async {
    final (repo, adapter) = await repoWith({
      '/products/price-sources/demirprofil': [
        (status: 200, body: {'price_source': demirSourceJson(), 'recomputed': 12}),
      ],
    });
    final res = await repo.updatePriceSource(
      'demirprofil',
      const PriceSourceSettingsBody(
        markupPercent: 12.5,
        autoSync: false,
        categoryMarkups: [PriceSourceCategoryMarkup(category: 'Sac', markupPercent: 10)],
      ),
    );
    expect(res.recomputed, 12);
    expect(adapter.requestBodies.single, {
      'markup_percent': 12.5,
      'auto_sync': false,
      'category_markups': [
        {'category': 'Sac', 'markup_percent': 10.0},
      ],
    });
  });

  test('price-changes + summary sorguları', () async {
    final (repo, adapter) = await repoWith({
      '/products/price-changes': [
        (status: 200, body: {'changes': changesJson(), 'total': 3, 'page': 1, 'limit': 50}),
      ],
      '/products/price-changes/summary': [(status: 200, body: summaryJson())],
    });
    const PriceChangesQuery q = (
      from: kUlasEventAt,
      to: kUlasEventAt,
      reason: 'supplier',
      source: 'ulas',
      direction: 'all',
      category: '',
      q: '',
      sort: 'newest',
    );
    final list = await repo.priceChanges(q);
    expect(list.changes.first.oldSourcePrice, 460);
    expect(adapter.requestQueries[0], {
      'from': kUlasEventAt,
      'to': kUlasEventAt,
      'reason': 'supplier',
      'source': 'ulas',
      'direction': 'all',
      'sort': 'newest',
      'page': '1',
      'limit': '$kPriceChangesPageSize',
    });
    await repo.priceChangeSummary((from: '2026-08-30', to: '2026-09-28', reason: 'all', source: ''));
    expect(adapter.requestQueries[1], {'from': '2026-08-30', 'to': '2026-09-28', 'reason': 'all'});
  });
}

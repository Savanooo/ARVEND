import '../../../core/api/api_client.dart';
import '../domain/price_change.dart';
import '../domain/price_source.dart';
import '../domain/product.dart';

/// Ürün kataloğu sayfa boyutu. Backend sayfa başına en fazla 200 döndürür;
/// 200 üstü limit SESSİZCE 50'ye düşer (ProductService.List) -- bu yüzden
/// katalog sayfa sayfa çekilir (web ile aynı 100).
const kProductsPageSize = 100;

/// Ürünler / Fiyat Kaynakları / Zam Geçmişi uçları (backend router.go
/// `/products`): okuma products.read, yazma (ürün ekle/düzenle, kaynak
/// ayarı, senkron) products.manage. Tedarikçi fiyatı ve kâr oranları
/// yalnızca products.manage sahibine döner -- bu sınıf gelen `null`ları
/// olduğu gibi taşır, hiçbir maliyet değeri TÜRETMEZ.
class ProductsRepository {
  ProductsRepository(this._client);
  final ApiClient _client;

  /// `q` yalnızca ürün adında arar (backend normalize edilmiş ad).
  Future<ProductPage> list({String q = '', int page = 1, int limit = kProductsPageSize}) async {
    final json = await _client.get<Map<String, dynamic>>('/products', query: {
      'page': '$page',
      'limit': '$limit',
      if (q.isNotEmpty) 'q': q,
    });
    return ProductPage.fromJson(json);
  }

  Future<Product> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/products/${Uri.encodeComponent(id)}');
    return Product.fromJson(json);
  }

  Future<List<PriceHistoryEntry>> priceHistory(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/products/${Uri.encodeComponent(id)}/price-history');
    return ((json['history'] as List?) ?? const []).cast<Map<String, dynamic>>().map(PriceHistoryEntry.fromJson).toList();
  }

  Future<Product> create(ProductInput input) async {
    final json = await _client.post<Map<String, dynamic>>('/products', data: input.toJson());
    return Product.fromJson(json);
  }

  /// Fiyat değişirse backend fiyat geçmişine otomatik bir "manual" kaydı
  /// düşer (UpdateProductWithPriceHistory) -- istemci ayrıca yazmaz.
  Future<Product> update(String id, ProductInput input) async {
    final json = await _client.put<Map<String, dynamic>>('/products/${Uri.encodeComponent(id)}', data: input.toJson());
    return Product.fromJson(json);
  }

  Future<List<PriceSource>> priceSources() async {
    final json = await _client.get<Map<String, dynamic>>('/products/price-sources');
    return ((json['sources'] as List?) ?? const []).cast<Map<String, dynamic>>().map(PriceSource.fromJson).toList();
  }

  /// 409 = başka bir senkron sürüyor; 502 = kaynağa ulaşılamadı ya da liste
  /// çok kısa (bkz. priceSyncErrorMessage).
  Future<PriceSyncResult> syncPriceSource(String source) async {
    final json = await _client.post<Map<String, dynamic>>('/products/price-sources/${Uri.encodeComponent(source)}/sync');
    return PriceSyncResult.fromJson(json);
  }

  /// Gövde TAM durumdur: markup_percent, auto_sync ve category_markups her
  /// zaman gönderilir.
  Future<PriceSourceUpdateResult> updatePriceSource(String source, PriceSourceSettingsBody body) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/products/price-sources/${Uri.encodeComponent(source)}',
      data: body.toJson(),
    );
    return PriceSourceUpdateResult.fromJson(json);
  }

  Future<PriceChangeList> priceChanges(PriceChangesQuery query, {int page = 1, int limit = kPriceChangesPageSize}) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/products/price-changes',
      query: priceChangesQueryParams(query, page: page, limit: limit),
    );
    return PriceChangeList.fromJson(json);
  }

  Future<PriceChangeSummary> priceChangeSummary(PriceChangeSummaryQuery query) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/products/price-changes/summary',
      query: summaryQueryParams(query),
    );
    return PriceChangeSummary.fromJson(json);
  }
}

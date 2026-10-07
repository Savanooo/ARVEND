import 'package:dio/dio.dart' show CancelToken;

import '../../../core/api/api_client.dart';
import '../domain/price_change.dart';
import '../domain/price_source.dart';
import '../domain/product.dart';

/// Ürün kataloğu sayfa boyutu. Backend sayfa başına en fazla 200 döndürür;
/// 200 üstü limit SESSİZCE 50'ye düşer (ProductService.List) -- bu yüzden
/// katalog sayfa sayfa çekilir (web ile aynı 100).
const kProductsPageSize = 100;

/// Teklif formunda bir kalemin altında gösterilen öneri sayısı -- küçük
/// telefonda klavye açıkken de kart taşmasın.
const kProductSuggestionLimit = 6;

/// Ürünler / Fiyat Kaynakları / Zam Geçmişi uçları (backend router.go
/// `/products`): okuma products.read, yazma (ürün ekle/düzenle, kaynak
/// ayarı, senkron) products.manage. Tedarikçi fiyatı ve kâr oranları
/// yalnızca products.manage sahibine döner -- bu sınıf gelen `null`ları
/// olduğu gibi taşır, hiçbir maliyet değeri TÜRETMEZ.
class ProductsRepository {
  ProductsRepository(this._client);
  final ApiClient _client;

  /// `q` kelime bazlıdır: her kelime adda, kategoride ya da tedarikçide
  /// geçmeli ("demir" Demir Profil ürünlerini, "kutu 40" 40'lı kutu
  /// profilleri bulur); ad eşleşmesi önce sıralanır (bkz. API_CONTRACT.md).
  Future<ProductPage> list({String q = '', int page = 1, int limit = kProductsPageSize}) async {
    final json = await _client.get<Map<String, dynamic>>('/products', query: {
      'page': '$page',
      'limit': '$limit',
      if (q.isNotEmpty) 'q': q,
    });
    return ProductPage.fromJson(json);
  }

  /// Teklif kalemindeki katalog önerileri: aramanın ilk [limit] sonucu
  /// (en iyi eşleşmeler önce) ve toplam eşleşme sayısı. [cancelToken]:
  /// kullanıcı yazmaya devam edince eski istek iptal edilir.
  Future<ProductPage> suggest(String q, {int limit = kProductSuggestionLimit, CancelToken? cancelToken}) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/products',
      query: {'page': '1', 'limit': '$limit', 'q': q},
      cancelToken: cancelToken,
    );
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

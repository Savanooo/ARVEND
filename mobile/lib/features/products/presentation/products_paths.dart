/// Ürünler modülünün mutlak rotaları -- "Diğer" dalının altında (bkz.
/// products_routes.dart; entegrasyon adımı `/diger` altına bağlar).
abstract final class ProductsPaths {
  static const list = '/diger/urunler';
  static const create = '/diger/urunler/yeni';
  static const sources = '/diger/urunler/kaynaklar';
  static const priceChanges = '/diger/urunler/zamlar';

  static String detail(String id) => '$list/${Uri.encodeComponent(id)}';
  static String edit(String id) => '${detail(id)}/duzenle';

  /// Zam Geçmişi, verilen filtrelerle (web URL parametreleriyle aynı adlar).
  static String priceChangesWith(Map<String, String> query) =>
      query.isEmpty ? priceChanges : Uri(path: priceChanges, queryParameters: query).toString();
}

/// İzin kodları (backend domain.PermProducts*).
abstract final class ProductsPermissions {
  /// Katalog, fiyat kaynağı durumu, fiyat geçmişi ve Zam Geçmişi.
  static const read = 'products.read';

  /// Ürün ekle/düzenle, kaynak senkronu, kâr oranı ayarları; tedarikçi
  /// fiyatı ve kâr oranları da yalnızca bu izinle döner.
  static const manage = 'products.manage';
}

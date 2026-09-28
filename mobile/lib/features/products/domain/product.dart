/// backend `productResponse` (internal/httpapi/handler/product_handler.go).
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.unit,
    required this.unitPrice,
    required this.description,
    required this.category,
    required this.source,
    this.sourceSyncedAt,
    this.sourcePrice,
  });

  final String id;
  final String name;
  final String unit;

  /// Satış fiyatı (kâr oranı uygulanmış) -- products.read olan herkese açık.
  final double unitPrice;
  final String description;
  final String category;

  /// Tedarikçi fiyat kaynağı ("ulas", "demirprofil"); elle eklenen üründe "".
  final String source;

  /// Ürünün kaynak listede EN SON görüldüğü an (RFC3339); hiç senkronlanmamış
  /// (BYZ'den aktarılmış) üründe null.
  final String? sourceSyncedAt;

  /// Kâr oranı uygulanmamış tedarikçi (maliyet) fiyatı -- backend YALNIZCA
  /// products.manage sahibine döndürür; diğerlerinde ve kaynak fiyatı
  /// bilinmeyen üründe null. Satış fiyatı + oran = maliyet olduğundan
  /// ekranlar bunu ayrıca `canAccess('products.manage')` ile de süzer.
  final double? sourcePrice;

  bool get isManual => source.isEmpty;

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    unit: json['unit'] as String? ?? '',
    unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
    description: json['description'] as String? ?? '',
    category: json['category'] as String? ?? '',
    source: json['source'] as String? ?? '',
    sourceSyncedAt: json['source_synced_at'] as String?,
    sourcePrice: (json['source_price'] as num?)?.toDouble(),
  );
}

/// GET /products -> `{products, total}`. Backend sayfa başına en fazla 200
/// ürün döndürür; 200 üstü limit SESSİZCE 50'ye düşer (ProductService.List).
class ProductPage {
  const ProductPage({required this.products, required this.total});
  final List<Product> products;
  final int total;

  factory ProductPage.fromJson(Map<String, dynamic> json) => ProductPage(
    products: ((json['products'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Product.fromJson).toList(),
    total: (json['total'] as num?)?.toInt() ?? 0,
  );
}

/// product_price_history.reason (migration 0046): supplier = tedarikçi
/// listesinde fiyat değişti; markup = kâr oranı yeniden uygulandı; manual =
/// elle ürün düzenleme.
abstract final class PriceChangeReason {
  static const supplier = 'supplier';
  static const markup = 'markup';
  static const manual = 'manual';
  static const values = [supplier, markup, manual];
}

/// GET /products/{id}/price-history -> `{history: [...]}`.
class PriceHistoryEntry {
  const PriceHistoryEntry({
    required this.oldPrice,
    required this.newPrice,
    required this.note,
    required this.changedAt,
    required this.reason,
    this.source,
    this.oldSourcePrice,
    this.newSourcePrice,
  });

  final double oldPrice;
  final double newPrice;

  /// Değişikliğin kaynağı (ör. "Ulaş fiyat listesi"); elle düzenlemede "".
  final String note;
  final String changedAt;
  final String reason;

  /// Tedarikçi kodu; elle düzenlemede null.
  final String? source;

  /// Tedarikçi fiyatları: yalnızca products.manage sahibine döner.
  final double? oldSourcePrice;
  final double? newSourcePrice;

  factory PriceHistoryEntry.fromJson(Map<String, dynamic> json) => PriceHistoryEntry(
    oldPrice: (json['old_price'] as num?)?.toDouble() ?? 0,
    newPrice: (json['new_price'] as num?)?.toDouble() ?? 0,
    note: json['note'] as String? ?? '',
    changedAt: json['changed_at'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    source: _nonEmpty(json['source'] as String?),
    oldSourcePrice: (json['old_source_price'] as num?)?.toDouble(),
    newSourcePrice: (json['new_source_price'] as num?)?.toDouble(),
  );
}

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

/// Ürün formunun gönderdiği alanlar -- backend `upsertProductRequest`
/// (name/unit/unit_price/description/category) ile BİREBİR; başka alan
/// İCAT EDİLMEZ.
class ProductInput {
  const ProductInput({
    required this.name,
    required this.unit,
    required this.unitPrice,
    this.description = '',
    this.category = '',
  });

  final String name;
  final String unit;
  final double unitPrice;
  final String description;
  final String category;

  Map<String, dynamic> toJson() => {
    'name': name,
    'unit': unit,
    'unit_price': unitPrice,
    'description': description,
    'category': category,
  };
}

/// Fiyat girişi: "1234,56", "1234.56", "1.234,56" kabul edilir. Virgül
/// varsa ondalık virgüldür (noktalar binlik ayırıcı sayılıp atılır); yoksa
/// nokta ondalıktır. İkiden fazla ondalık reddedilir ("1.234" gibi belirsiz
/// yazımlar da böylece fiyat 1,234 sanılmaz). null = geçersiz.
({double? value, String? error}) parsePriceInput(String raw) {
  final s = raw.trim().replaceAll(' ', '').replaceAll(' ', '');
  if (s.isEmpty) return (value: null, error: 'Birim fiyat gir.');
  final normalized = s.contains(',') ? s.replaceAll('.', '').replaceAll(',', '.') : s;
  final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(normalized);
  if (m == null) return (value: null, error: 'Geçerli bir fiyat gir (ör. 1250 veya 1250,50).');
  if ((m.group(2) ?? '').length > 2) {
    return (value: null, error: 'En fazla iki ondalık basamak girilebilir.');
  }
  final value = double.parse(normalized);
  if (value > kMaxProductPrice) return (value: null, error: 'Fiyat en fazla 999.999.999.999,99 TL olabilir.');
  return (value: value, error: null);
}

/// Birim fiyatın üst sınırı: sunucunun ham "numeric field overflow"
/// hatasına düşmeden, gerçekçi bir tavan.
const kMaxProductPrice = 999999999999.99;

/// Ürün alanlarının veritabanı sınırları (products: name varchar(200),
/// unit varchar(30), category varchar(100)). Backend uzunluğu doğrulamaz;
/// aşan metin ham, İngilizce bir PostgreSQL hatası döndürürdü -- form
/// yazarken keser.
abstract final class ProductFieldLimits {
  static const name = 200;
  static const unit = 30;
  static const category = 100;
}

/// Formun başlangıç değeri: 575.5 -> "575,50", 12 -> "12" (binlik ayırıcısız).
String formatPriceInput(double value) {
  final cents = (value * 100).round();
  if (cents % 100 == 0) return (cents ~/ 100).toString();
  final whole = cents ~/ 100;
  final frac = (cents % 100).abs().toString().padLeft(2, '0');
  return '$whole,$frac';
}

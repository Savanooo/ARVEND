/// Metraj reçeteleri yönetimi (web `/admin/metraj-hesaplama`) -- Grup ->
/// Kategori (hesaplama türü) -> Reçete kalemi üç seviyeli katalog.
///
/// `calculations` özelliğindeki (Metraj Hesapla paneli) modellerden BİLİNÇLİ
/// OLARAK ayrı tutulur: panel yalnızca aktif grup/kategori kaskadını okur,
/// burada ise yönetim ekranının ihtiyaç duyduğu tüm alanlar (slug, sıra,
/// aktiflik, reçete katsayıları) vardır. Sayısal reçete alanları backend'in
/// bilinçli tercihiyle JSON STRING'dir (bkz. API_CONTRACT.md "Money/quantity
/// serialization") -- burada da String tutulur, mobilde hiç hesap yapılmaz.
library;

import 'package:intl/intl.dart';

/// `GET /calculations/groups` satırı. Backend yalnızca AKTİF grupları
/// döner (bkz. calc.sql ListCalcGroups) -- pasifleştirilen grup listeden
/// düşer, web ile aynı davranış.
class CalcAdminGroup {
  final String id;
  final String slug;
  final String name;
  final String description;
  final int sortOrder;
  final bool isActive;

  const CalcAdminGroup({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.sortOrder,
    required this.isActive,
  });

  factory CalcAdminGroup.fromJson(Map<String, dynamic> json) => CalcAdminGroup(
    id: json['id'] as String,
    slug: json['slug'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    isActive: json['is_active'] as bool? ?? true,
  );
}

/// `GET /calculations/categories?group_id=X` satırı (düz liste şekli).
class CalcAdminCategory {
  final String id;
  final String groupId;
  final String slug;
  final String name;
  final String description;

  /// Web formu kaydederken mevcut görseli korumak için geri gönderir --
  /// mobilde görsel yönetimi yok, ama değer aynen korunur (aksi halde PUT
  /// görsel bağlantısını sessizce silerdi).
  final String? imageFileId;
  final int sortOrder;
  final bool isActive;

  const CalcAdminCategory({
    required this.id,
    required this.groupId,
    required this.slug,
    required this.name,
    required this.description,
    required this.imageFileId,
    required this.sortOrder,
    required this.isActive,
  });

  factory CalcAdminCategory.fromJson(Map<String, dynamic> json) => CalcAdminCategory(
    id: json['id'] as String,
    groupId: json['group_id'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    imageFileId: json['image_file_id'] as String?,
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    isActive: json['is_active'] as bool? ?? true,
  );
}

/// Backend `calculation_type` değerleri -- web `CALC_TYPE_LABELS` ile aynı.
abstract final class CalcType {
  static const areaBased = 'area_based';
  static const perimeterBased = 'perimeter_based';
  static const fixed = 'fixed';

  static const labels = <String, String>{
    areaBased: 'Alan bazlı (m²)',
    perimeterBased: 'Çevre bazlı (m)',
    fixed: 'Sabit',
  };

  static String label(String value) => labels[value] ?? value;
}

/// Backend `rounding_type` değerleri -- web `ROUNDING_LABELS` ile aynı.
abstract final class CalcRounding {
  static const none = 'none';
  static const ceil = 'ceil';
  static const round = 'round';

  static const labels = <String, String>{
    none: 'Yok (ham değer)',
    ceil: 'Yukarı yuvarla (tam sayı/paket)',
    round: 'En yakına yuvarla (2 ondalık)',
  };

  static String label(String value) => labels[value] ?? value;
}

/// `GET /calculations/recipe-items?category_id=X` satırı (aktif + pasif).
class CalcRecipeItem {
  final String id;
  final String categoryId;
  final String? productId;
  final String materialName;
  final String unit;
  final String calculationType;
  final String quantityPerM2;
  final String quantityPerMeter;
  final String fixedQuantity;
  final String wastePercent;
  final String roundingType;
  final String? minQuantity;
  final String? packageSize;
  final String referenceUnitPrice;
  final String groupName;
  final int sortOrder;
  final bool isActive;
  final String? notes;

  const CalcRecipeItem({
    required this.id,
    required this.categoryId,
    required this.productId,
    required this.materialName,
    required this.unit,
    required this.calculationType,
    required this.quantityPerM2,
    required this.quantityPerMeter,
    required this.fixedQuantity,
    required this.wastePercent,
    required this.roundingType,
    required this.minQuantity,
    required this.packageSize,
    required this.referenceUnitPrice,
    required this.groupName,
    required this.sortOrder,
    required this.isActive,
    required this.notes,
  });

  factory CalcRecipeItem.fromJson(Map<String, dynamic> json) => CalcRecipeItem(
    id: json['id'] as String,
    categoryId: json['category_id'] as String? ?? '',
    productId: _nonEmpty(json['product_id'] as String?),
    materialName: json['material_name'] as String? ?? '',
    unit: json['unit'] as String? ?? '',
    calculationType: json['calculation_type'] as String? ?? CalcType.areaBased,
    quantityPerM2: json['quantity_per_m2'] as String? ?? '0',
    quantityPerMeter: json['quantity_per_meter'] as String? ?? '0',
    fixedQuantity: json['fixed_quantity'] as String? ?? '0',
    wastePercent: json['waste_percent'] as String? ?? '0',
    roundingType: json['rounding_type'] as String? ?? CalcRounding.none,
    minQuantity: json['min_quantity'] as String?,
    packageSize: json['package_size'] as String?,
    referenceUnitPrice: json['reference_unit_price'] as String? ?? '0',
    groupName: json['group_name'] as String? ?? '',
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    isActive: json['is_active'] as bool? ?? true,
    notes: json['notes'] as String?,
  );

  /// Seçili hesap türünde GERÇEKTEN kullanılan katsayı (web tablosunun
  /// "Katsayı" sütunuyla aynı seçim).
  String get activeFactor => switch (calculationType) {
    CalcType.perimeterBased => quantityPerMeter,
    CalcType.fixed => fixedQuantity,
    _ => quantityPerM2,
  };
}

String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

/// Reçete kalemi oluştur/güncelle gövdesi -- web `RecipeItemsEditor`
/// payload'ının birebir aynısı. Sayısal alanlar string gider; boş
/// bırakılan zorunlu-ama-varsayılanlı alanlar "0", boş opsiyoneller null.
class CalcRecipeItemInput {
  final String categoryId;
  final String? productId;
  final String materialName;
  final String unit;
  final String calculationType;
  final String quantityPerM2;
  final String quantityPerMeter;
  final String fixedQuantity;
  final String wastePercent;
  final String roundingType;
  final String minQuantity;
  final String packageSize;
  final String referenceUnitPrice;
  final String groupName;
  final int sortOrder;
  final bool isActive;
  final String notes;

  const CalcRecipeItemInput({
    required this.categoryId,
    required this.productId,
    required this.materialName,
    required this.unit,
    required this.calculationType,
    required this.quantityPerM2,
    required this.quantityPerMeter,
    required this.fixedQuantity,
    required this.wastePercent,
    required this.roundingType,
    required this.minQuantity,
    required this.packageSize,
    required this.referenceUnitPrice,
    required this.groupName,
    required this.sortOrder,
    required this.isActive,
    required this.notes,
  });

  Map<String, dynamic> toJson() => {
    'category_id': categoryId,
    'product_id': (productId == null || productId!.isEmpty) ? null : productId,
    'material_name': materialName.trim(),
    'unit': unit.trim(),
    'calculation_type': calculationType,
    'quantity_per_m2': normalizeDecimal(quantityPerM2) ?? '0',
    'quantity_per_meter': normalizeDecimal(quantityPerMeter) ?? '0',
    'fixed_quantity': normalizeDecimal(fixedQuantity) ?? '0',
    'waste_percent': normalizeDecimal(wastePercent) ?? '0',
    'rounding_type': roundingType,
    'min_quantity': normalizeDecimal(minQuantity),
    'package_size': normalizeDecimal(packageSize),
    'reference_unit_price': normalizeDecimal(referenceUnitPrice) ?? '0',
    'group_name': groupName.trim(),
    'sort_order': sortOrder,
    'is_active': isActive,
    'notes': notes.trim().isEmpty ? null : notes.trim(),
  };
}

/// Türkçe sayı girişini backend'in beklediği noktalı string'e çevirir
/// (backend `decimal.NewFromString` virgülü reddeder). Kurallar:
/// - Virgül ondalıktır: "1,05" -> "1.05". Virgül varsa noktalar binlik
///   ayırıcıdır ve düzgün gruplanmış olmalıdır: "1.250,5" -> "1250.5".
/// - Virgül yoksa nokta ondalık sayılır ("1.05", "0.125", "3.6") -- AMA
///   "1.250" gibi binlik ayırıcıya benzeyen yazım BELİRSİZDİR ve reddedilir:
///   Türkçe okunuşu bin iki yüz elli, noktalı ondalık okunuşu bir virgül iki
///   yüz elli (1000 kat fark sessizce kaydedilmesin).
/// Boş -> (value: null, error: null).
({String? value, CalcDecimalError? error}) parseCalcDecimal(String raw) {
  final s = raw.trim().replaceAll(' ', '').replaceAll('\u00a0', '');
  if (s.isEmpty) return (value: null, error: null);
  if (s.startsWith('-')) return (value: null, error: CalcDecimalError.negative);
  String normalized;
  if (s.contains(',')) {
    final comma = s.indexOf(',');
    if (comma != s.lastIndexOf(',')) return (value: null, error: CalcDecimalError.invalid);
    final whole = s.substring(0, comma);
    final fraction = s.substring(comma + 1);
    if (whole.contains('.') && !RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(whole)) {
      return (value: null, error: CalcDecimalError.invalid);
    }
    normalized = '${whole.replaceAll('.', '')}.$fraction';
    if (!RegExp(r'^\d+\.\d+$').hasMatch(normalized)) return (value: null, error: CalcDecimalError.invalid);
  } else {
    if (RegExp(r'^[1-9]\d{0,2}(\.\d{3})+$').hasMatch(s)) return (value: null, error: CalcDecimalError.ambiguous);
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return (value: null, error: CalcDecimalError.invalid);
    normalized = s;
  }
  return (value: normalized, error: null);
}

enum CalcDecimalError { invalid, negative, ambiguous }

/// Geçerli girişi noktalı string'e çevirir; boş ya da geçersizse null
/// (form önce [validateDecimalField] ile doğrular).
String? normalizeDecimal(String raw) => parseCalcDecimal(raw).value;

/// Reçete sayısal alanlarının üst sınırları -- veritabanı sütunları
/// (quantity_per_m2/meter numeric(14,6), fixed/min/paket numeric(14,4),
/// waste_percent numeric(5,2), reference_unit_price numeric(18,2)).
/// Backend uzunluk/aralık denetlemez; aşan değer ham "numeric field
/// overflow" hatası döndürürdü.
abstract final class CalcLimits {
  static const perUnitFactor = 99999999.999999;
  static const quantity = 9999999999.9999;
  static const wastePercent = 999.99;
  static const referencePrice = 999999999999.99;
  static const materialName = 200;
  static const unit = 30;
  static const groupName = 60;
  static const nodeName = 120;
  static const categoryName = 160;
  static const slug = 80;
}

/// Reçete sayısal alanı ön-kontrolü -- backend'in AYNI kuralını
/// (negatif olamaz; paket büyüklüğü verilmişse > 0) yalnızca daha hızlı ve
/// anlaşılır geri bildirim için erken yakalar; ayrıca sütun sınırlarını
/// ([max], [maxDecimals]) aşan değeri Türkçe bir mesajla durdurur.
String? validateDecimalField(
  String raw, {
  required String label,
  bool positive = false,
  double? max,
  int? maxDecimals,
}) {
  final parsed = parseCalcDecimal(raw);
  switch (parsed.error) {
    case CalcDecimalError.negative:
      return '$label negatif olamaz';
    case CalcDecimalError.ambiguous:
      return '$label belirsiz: ondalık için virgül kullan (ör. 1,25), binlik ayırıcı yazma (ör. 1250)';
    case CalcDecimalError.invalid:
      return '$label geçerli bir sayı olmalı';
    case null:
      break;
  }
  final v = parsed.value;
  if (v == null) return null;
  final n = double.parse(v);
  if (positive && n <= 0) return "$label 0'dan büyük olmalı";
  final dot = v.indexOf('.');
  if (maxDecimals != null && dot >= 0 && v.length - dot - 1 > maxDecimals) {
    return '$label en fazla $maxDecimals ondalık basamak olabilir';
  }
  if (max != null && n > max) return '$label en fazla ${formatCalcNumber('$max')} olabilir';
  return null;
}

final _calcDisplayFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 0
  ..maximumFractionDigits = 6;

/// Ekranda gösterim: Türkçe ondalık virgül, gereksiz sıfırlar kırpılır,
/// binlikler gruplanır ("1.050000" -> "1,05", "1250" -> "1.250"). Sayı
/// değilse aynen döner.
String formatCalcNumber(String value) {
  final n = double.tryParse(value);
  return n == null ? value : _calcDisplayFormat.format(n);
}

/// Forma başlangıç değeri: virgüllü, GRUPLAMASIZ ("1.050000" -> "1,05",
/// "1250.000000" -> "1250") -- tekrar okunduğunda belirsiz olmasın.
String formatCalcInput(String? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final n = double.tryParse(value);
  if (n == null) return value;
  final fixed = n.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return fixed.replaceAll('.', ',');
}

/// Referans fiyatın forma başlangıç değeri: "575.50" -> "575,50",
/// "1250.00" -> "1250" (gruplamasız, iki ondalık).
String formatCalcPriceInput(String value) {
  final n = double.tryParse(value);
  if (n == null) return value;
  final cents = (n * 100).round();
  if (cents % 100 == 0) return '${cents ~/ 100}';
  return '${cents ~/ 100},${(cents % 100).toString().padLeft(2, '0')}';
}

/// Web `slugify` ile aynı dönüşüm: Türkçe karakterler sadeleşir, harf/rakam
/// dışı her şey tek tireye iner. Yalnızca bir KOLAYLIK -- kullanıcı slug'ı
/// elle de değiştirebilir, benzersizliği backend (organization_id, slug)
/// kısıtı uygular.
String slugify(String name) {
  // Dart'ın toLowerCase'i Türkçe değil: "İ" -> "i̇" (noktalı birleşik harf)
  // olurdu. Önce Türkçe büyük harfler elle indirilir.
  final lower = name.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();
  const map = {'ğ': 'g', 'ü': 'u', 'ş': 's', 'ı': 'i', 'ö': 'o', 'ç': 'c'};
  final buffer = StringBuffer();
  for (final ch in lower.split('')) {
    buffer.write(map[ch] ?? ch);
  }
  return buffer.toString().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Ürün aramasında karşılaştırma anahtarı: Dart'ın `toLowerCase`'i Türkçe
/// değildir ("DEMİR" -> "demi̇r", "DEMIR" -> "demir"), büyük harfli
/// katalog adlarında (ör. Demir Profil listesi) "demir" araması bulamazdı.
/// İ/I/ı hepsi "i"ye indirilir -- arama bilerek hoşgörülüdür.
String searchFold(String value) => value
    .replaceAll('İ', 'i')
    .replaceAll('I', 'i')
    .toLowerCase()
    .replaceAll('ı', 'i')
    // Ayrışık yazılmış "i̇" (i + U+0307 birleşik nokta) da düz "i" olur.
    .replaceAll('̇', '');

/// Ürün seçici/ad eşleştirme için ürünün YALNIZCA gereken alt kümesi.
/// Tedarikçi alış fiyatı (`source_price`) ve kâr oranları BİLİNÇLİ OLARAK
/// okunmaz -- bu ekranda hiç görünmemeli (yalnızca products.manage'e döner).
class CalcProductOption {
  final String id;
  final String name;
  final String unit;
  final double unitPrice;

  const CalcProductOption({required this.id, required this.name, required this.unit, required this.unitPrice});

  factory CalcProductOption.fromJson(Map<String, dynamic> json) => CalcProductOption(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    unit: json['unit'] as String? ?? '',
    unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
  );
}

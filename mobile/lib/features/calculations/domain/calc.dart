import '../../offers/domain/offer.dart';

/// bkz. mobile/API_CONTRACT.md#calculations - TÜM sayısal alanlar JSON
/// string'idir (backend'in bilinçli tercihi); burada da String olarak
/// tutulup yalnızca görüntülemede parse edilir (Formatters.moneyFromString /
/// quantityFromString) - mobilde hiçbir yeniden hesap yapılmaz.
class CalcCategory {
  final String id;
  final String groupId;
  final String? groupSlug;
  final String? groupName;
  final String slug;
  final String name;
  final String description;

  const CalcCategory({
    required this.id,
    required this.groupId,
    required this.groupSlug,
    required this.groupName,
    required this.slug,
    required this.name,
    required this.description,
  });

  factory CalcCategory.fromJson(Map<String, dynamic> json) => CalcCategory(
        id: json['id'] as String,
        groupId: json['group_id'] as String,
        groupSlug: json['group_slug'] as String?,
        groupName: json['group_name'] as String?,
        slug: json['slug'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
      );
}

class CalcGroupWithCategories {
  final String id;
  final String slug;
  final String name;
  final List<CalcCategory> categories;

  const CalcGroupWithCategories({
    required this.id,
    required this.slug,
    required this.name,
    required this.categories,
  });

  factory CalcGroupWithCategories.fromJson(Map<String, dynamic> json) => CalcGroupWithCategories(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        categories: (json['categories'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(CalcCategory.fromJson)
            .toList(),
      );

  /// Çatı hesaplamalarında pitch alanı gösterimi için saf bir UX ipucu
  /// (backend'de bu isimle bir kısıt yok - frontend'deki aynı sezgisel
  /// kural, bkz. web MetrajHesaplaPanel.tsx).
  bool get looksLikeRoof => name.toLowerCase().contains('çatı') || slug.contains('cati');
}

class CalcWarning {
  final String? itemId;
  final String code;
  final String message;

  const CalcWarning({required this.itemId, required this.code, required this.message});

  factory CalcWarning.fromJson(Map<String, dynamic> json) => CalcWarning(
        itemId: json['item_id'] as String?,
        code: json['code'] as String,
        message: json['message'] as String,
      );
}

class CalcResultItem {
  final String recipeItemId;
  final String materialName;
  final String unit;
  final String quantity;
  final String? productId;
  final String unitPrice;
  final String lineTotal;
  final String? groupName;
  final String calculationType;
  final String factor;
  final String wastePercent;
  final String roundingType;

  /// Reçetedeki minimum miktar ve paket büyüklüğü (doluysa miktar paket
  /// sayısıdır); kural yoksa ya da eski sunucu göndermiyorsa null.
  final String? minQuantity;
  final String? packageSize;

  /// `unit_price` nereden geldi: product | reference (ürün fiyatı yok/0,
  /// reçetenin referans fiyatı) | none (hiç fiyat yok, 0). Alanı göndermeyen
  /// eski sunucuda ''.
  final String priceSource;

  /// Ürün fiyatı kullanılamadıysa sunucunun kısa Türkçe sebebi
  /// ("referans fiyat kullanıldı" / "fiyat yok"); aksi halde null.
  final String? priceWarning;

  static const priceSourceProduct = 'product';
  static const priceSourceReference = 'reference';
  static const priceSourceNone = 'none';

  bool get hasPriceWarning => priceWarning != null && priceWarning!.isNotEmpty;

  /// Teklif miktarı 2 ondalıklıdır: miktarı 0 olan (ör. çevre girilmediği
  /// için 0 dönen) ya da 0,01'in altında kalan satır teklife eklenemez --
  /// teklif formu böyle bir satırı "Sıfırdan büyük olmalı" diye reddeder.
  bool get hasOfferQuantity => ((double.tryParse(quantity) ?? 0) * 100).round() > 0;

  const CalcResultItem({
    required this.recipeItemId,
    required this.materialName,
    required this.unit,
    required this.quantity,
    required this.productId,
    required this.unitPrice,
    required this.lineTotal,
    required this.groupName,
    required this.calculationType,
    required this.factor,
    required this.wastePercent,
    required this.roundingType,
    this.minQuantity,
    this.packageSize,
    this.priceSource = '',
    this.priceWarning,
  });

  factory CalcResultItem.fromJson(Map<String, dynamic> json) => CalcResultItem(
        recipeItemId: json['recipe_item_id'] as String,
        materialName: json['material_name'] as String,
        unit: json['unit'] as String,
        quantity: json['quantity'] as String,
        productId: json['product_id'] as String?,
        unitPrice: json['unit_price'] as String,
        lineTotal: json['line_total'] as String,
        groupName: json['group_name'] as String?,
        calculationType: json['calculation_type'] as String,
        factor: json['factor'] as String,
        wastePercent: json['waste_percent'] as String,
        roundingType: json['rounding_type'] as String,
        minQuantity: json['min_quantity'] as String?,
        packageSize: json['package_size'] as String?,
        priceSource: json['price_source'] as String? ?? '',
        priceWarning: json['price_warning'] as String?,
      );
}

/// Metraj sonucundaki fiyat uyarılarının özeti -- ekranda tek not olarak
/// gösterilir (satırlar ayrıca işaretlenir). Uyarı yoksa null.
String? calcPriceSummary(List<CalcResultItem> items) {
  final reference = items.where((i) => i.priceSource == CalcResultItem.priceSourceReference).length;
  final none = items.where((i) => i.priceSource == CalcResultItem.priceSourceNone).length;
  if (reference == 0 && none == 0) return null;
  final parts = [
    if (reference > 0) '$reference kalemde ürün fiyatı olmadığından reçetedeki referans fiyat kullanıldı',
    if (none > 0) '$none kalemin fiyatı yok (0 TL hesaplandı)',
  ];
  return '${parts.join('; ')}. Teklife eklemeden önce fiyatları kontrol edin; '
      'kalıcı çözüm için ürün fiyatlarını Ürünler ekranından girin.';
}

/// Satırlarda zaten işaretlenen fiyat uyarıları (ürün yok / ürün 0 TL)
/// üstteki uyarı listesinden çıkarılır -- yeni firmada her satır için bir
/// kutu tekrar etmesin. Eski sunucuda (satır işareti yok) hepsi kalır.
List<CalcWarning> nonPriceWarnings(CalcRunResult result) {
  final marked = {
    for (final i in result.items)
      if (i.hasPriceWarning) i.recipeItemId,
  };
  const priceCodes = {'product_missing', 'product_zero_price'};
  return result.warnings.where((w) => !(priceCodes.contains(w.code) && marked.contains(w.itemId))).toList();
}

class CalcRunResult {
  final String categoryId;
  final String categoryName;
  final String footprintArea;
  final String effectiveArea;
  final String? perimeter;

  /// Etkin alana uygulanan çatı eğimi (derece); eğim yoksa null.
  final String? pitchDeg;
  final List<CalcResultItem> items;
  final String totalCost;
  final List<CalcWarning> warnings;

  const CalcRunResult({
    required this.categoryId,
    required this.categoryName,
    required this.footprintArea,
    required this.effectiveArea,
    required this.perimeter,
    this.pitchDeg,
    required this.items,
    required this.totalCost,
    required this.warnings,
  });

  /// [requestedPitchDeg]: istekte gönderilen eğim. Sunucu uyguladığı
  /// eğimi `input.pitch_deg` ile bildirir; bu alanı hiç göndermeyen eski
  /// sunucuda gönderilen değer kullanılır.
  factory CalcRunResult.fromJson(Map<String, dynamic> json, {String? requestedPitchDeg}) {
    final category = json['category'] as Map<String, dynamic>;
    final input = json['input'] as Map<String, dynamic>;
    return CalcRunResult(
      categoryId: category['id'] as String,
      categoryName: category['name'] as String,
      footprintArea: input['footprint_area'] as String,
      effectiveArea: input['effective_area'] as String,
      perimeter: input['perimeter'] as String?,
      pitchDeg: input.containsKey('pitch_deg') ? input['pitch_deg'] as String? : requestedPitchDeg,
      items: (json['items'] as List).cast<Map<String, dynamic>>().map(CalcResultItem.fromJson).toList(),
      totalCost: json['total_cost'] as String,
      warnings: (json['warnings'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .map(CalcWarning.fromJson)
          .toList(),
    );
  }
}

/// Backend, doldurulmuş `area`/`width`/`height`/`perimeter`/`pitch_deg`
/// alanlarının 0'dan büyük olmasını şart koşar (bkz. backend
/// ComputeGeometry doğrulaması: mevcut-ama-<=0 bir değer AÇIKÇA
/// reddedilir, "alan yok" ile karıştırılmaz). Burada AYNI kural yalnızca
/// daha hızlı geri bildirim için istemci tarafında ÖN-KONTROL edilir --
/// gerçek sınır her zaman backend'dedir, bu fonksiyon backend'i
/// TEKRARLAMAZ, yalnızca aynı "> 0" şartını erken yakalar.
String? validatePositiveIfPresent(String raw, String fieldLabel) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  final n = double.tryParse(v.replaceAll(',', '.'));
  if (n == null) return "$fieldLabel geçerli bir sayı olmalı";
  if (n <= 0) return "$fieldLabel 0'dan büyük olmalı";
  return null;
}

/// Çatı eğimi (derece): boşsa eğim yok; doluysa 0'dan büyük ve 90'dan
/// küçük olmalı. 90° ve üstü bir eğimde etkin alan tanımsızdır: sunucu
/// 400 döner, eski sunucu ise eğimi sessizce yok sayıp düz alan
/// hesaplıyordu.
String? validatePitchIfPresent(String raw) {
  final err = validatePositiveIfPresent(raw, 'Çatı Eğimi');
  if (err != null) return err;
  final n = double.tryParse(raw.trim().replaceAll(',', '.'));
  if (n != null && n >= 90) return "Çatı Eğimi 90'dan küçük olmalı";
  return null;
}

/// Seçilen kalemleri teklife eklenecek `OfferItem` listesine çevirir --
/// backend'in `/calculations/run`'dan DÖNDÜRDÜĞÜ değerleri olduğu gibi
/// taşır, yeni bir hesap/formül İCAT ETMEZ. `calcSnapshot` web ile ortak
/// kanonik şemadadır (bkz. API_CONTRACT.md "calc_snapshot"; sunucu da
/// kayıtta bu şemaya getirir) ve burada TEK yerde inşa edilir -- hem
/// bağımsız Metraj ekranından hem de bir teklif taslağına "Metrajdan
/// Ekle" ile eklerken AYNI şekilde kullanılır. [groupName]: hesaplama
/// grubunun adı (ör. "Çatı Hesaplamaları").
List<OfferItem> buildOfferItemsFromCalcResult(
  CalcRunResult result,
  Set<String> selectedRecipeItemIds, {
  String? groupName,
}) {
  return result.items
      .where((i) => i.hasOfferQuantity && selectedRecipeItemIds.contains(i.recipeItemId))
      .map((i) => OfferItem(
            id: '',
            productId: i.productId,
            productName: i.materialName,
            quantity: double.tryParse(i.quantity) ?? 0,
            unitPrice: double.tryParse(i.unitPrice) ?? 0,
            lineTotal: 0,
            unit: i.unit,
            sectionLabel: result.categoryName,
            calcCategoryId: result.categoryId,
            calcSnapshot: {
              'area': result.effectiveArea,
              'footprint_area': result.footprintArea,
              'perimeter': result.perimeter,
              'pitch_deg': result.pitchDeg,
              'recipe_item_id': i.recipeItemId,
              'category_id': result.categoryId,
              'category_name': result.categoryName,
              if (groupName != null && groupName.isNotEmpty) 'group_name': groupName,
              'calculation_type': i.calculationType,
              'recipe_factor': i.factor,
              'waste_percent': i.wastePercent,
              if (i.minQuantity != null) 'min_quantity': i.minQuantity,
              if (i.packageSize != null) 'package_size': i.packageSize,
              'rounding_type': i.roundingType,
              'price_at_calc': i.unitPrice,
              // Fiyat ürün yerine reçete referansından geldiyse sonradan
              // "bu fiyat nereden?" sorusu yanıtlanabilsin.
              if (i.priceSource.isNotEmpty) 'price_source': i.priceSource,
            },
          ))
      .toList();
}

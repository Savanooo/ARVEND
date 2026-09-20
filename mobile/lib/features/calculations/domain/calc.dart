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
      );
}

class CalcRunResult {
  final String categoryId;
  final String categoryName;
  final String footprintArea;
  final String effectiveArea;
  final String? perimeter;
  final List<CalcResultItem> items;
  final String totalCost;
  final List<CalcWarning> warnings;

  const CalcRunResult({
    required this.categoryId,
    required this.categoryName,
    required this.footprintArea,
    required this.effectiveArea,
    required this.perimeter,
    required this.items,
    required this.totalCost,
    required this.warnings,
  });

  factory CalcRunResult.fromJson(Map<String, dynamic> json) {
    final category = json['category'] as Map<String, dynamic>;
    final input = json['input'] as Map<String, dynamic>;
    return CalcRunResult(
      categoryId: category['id'] as String,
      categoryName: category['name'] as String,
      footprintArea: input['footprint_area'] as String,
      effectiveArea: input['effective_area'] as String,
      perimeter: input['perimeter'] as String?,
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

/// Seçilen kalemleri teklife eklenecek `OfferItem` listesine çevirir --
/// backend'in `/calculations/run`'dan DÖNDÜRDÜĞÜ değerleri olduğu gibi
/// taşır, yeni bir hesap/formül İCAT ETMEZ. `calcSnapshot`'ın 11 alanı
/// (bkz. MOBILE_BACKEND_GAPS.md #10 -- backend bu şekli doğrulamaz,
/// yalnızca ham JSON olarak dondurur) burada TEK yerde inşa edilir, hem
/// bağımsız Metraj ekranından hem de bir teklif taslağına "Metrajdan
/// Ekle" ile eklerken AYNI şekilde kullanılır.
List<OfferItem> buildOfferItemsFromCalcResult(CalcRunResult result, Set<String> selectedRecipeItemIds) {
  return result.items
      .where((i) => selectedRecipeItemIds.contains(i.recipeItemId))
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
              'recipe_item_id': i.recipeItemId,
              'category_id': result.categoryId,
              'category_name': result.categoryName,
              'footprint_area': result.footprintArea,
              'effective_area': result.effectiveArea,
              'perimeter': result.perimeter,
              'calculation_type': i.calculationType,
              'factor': i.factor,
              'waste_percent': i.wastePercent,
              'rounding_type': i.roundingType,
              'price_at_calc': i.unitPrice,
            },
          ))
      .toList();
}

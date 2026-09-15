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

  const CalcCategory({
    required this.id,
    required this.groupId,
    required this.groupSlug,
    required this.groupName,
    required this.slug,
    required this.name,
  });

  factory CalcCategory.fromJson(Map<String, dynamic> json) => CalcCategory(
        id: json['id'] as String,
        groupId: json['group_id'] as String,
        groupSlug: json['group_slug'] as String?,
        groupName: json['group_name'] as String?,
        slug: json['slug'] as String,
        name: json['name'] as String,
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

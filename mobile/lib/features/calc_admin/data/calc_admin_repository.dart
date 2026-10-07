import '../../../core/api/api_client.dart';
import '../domain/calc_admin.dart';

/// Metraj reçeteleri yönetim uçları (backend router.go `/calculations`):
/// okuma `calculations.read`, yazma `calculations.manage`. Tekil grup/
/// kategori GET ucu YOK -- web gibi küçük listeden id ile bulunur.
class CalcAdminRepository {
  CalcAdminRepository(this._client);
  final ApiClient _client;

  /// Ürün listesi ucu sayfa başına en çok 200 döner, 200 üstü limit
  /// SESSİZCE 50'ye düşer (bkz. web lib/products.ts) -- tüm katalog sayfa
  /// sayfa çekilir.
  static const productPageSize = 200;
  static const _maxProductPages = 50;

  /// Pasifleştirilmiş gruplar DAHİL (`include_inactive=1`): yönetim
  /// ekranı onları rozetle gösterir ki yeniden aktifleştirilebilsin --
  /// eskiden pasife alınan grup listeden düşüp bir daha açılamıyordu.
  Future<List<CalcAdminGroup>> groups() async {
    final json = await _client.get<Map<String, dynamic>>('/calculations/groups', query: {'include_inactive': 1});
    return (json['groups'] as List? ?? const []).cast<Map<String, dynamic>>().map(CalcAdminGroup.fromJson).toList();
  }

  Future<CalcAdminGroup> createGroup({required String name, required String slug, required String description}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/calculations/groups',
      data: {
        'slug': slug.trim().isEmpty ? slugify(name) : slug.trim(),
        'name': name.trim(),
        'description': description.trim(),
        'sort_order': 0,
      },
    );
    return CalcAdminGroup.fromJson(json);
  }

  Future<CalcAdminGroup> updateGroup(
    String id, {
    required String name,
    required String slug,
    required String description,
    required int sortOrder,
    required bool isActive,
  }) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/calculations/groups/$id',
      data: {
        'slug': slug.trim(),
        'name': name.trim(),
        'description': description.trim(),
        'sort_order': sortOrder,
        'is_active': isActive,
      },
    );
    return CalcAdminGroup.fromJson(json);
  }

  /// [groups] ile aynı: pasif kategoriler de gelir.
  Future<List<CalcAdminCategory>> categories(String groupId) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/calculations/categories',
      query: {'group_id': groupId, 'include_inactive': 1},
    );
    return (json['categories'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CalcAdminCategory.fromJson)
        .toList();
  }

  Future<CalcAdminCategory> createCategory({
    required String groupId,
    required String name,
    required String slug,
    required String description,
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/calculations/categories',
      data: {
        'group_id': groupId,
        'slug': slug.trim().isEmpty ? slugify(name) : slug.trim(),
        'name': name.trim(),
        'description': description.trim(),
        'sort_order': 0,
      },
    );
    return CalcAdminCategory.fromJson(json);
  }

  /// Web `EditCategoryForm` ile aynı gövde -- mevcut `image_file_id` AYNEN
  /// geri gönderilir (mobilde görsel düzenleme yok, bağlantı korunur).
  Future<CalcAdminCategory> updateCategory(
    CalcAdminCategory existing, {
    required String name,
    required String slug,
    required String description,
    required int sortOrder,
    required bool isActive,
  }) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/calculations/categories/${existing.id}',
      data: {
        'group_id': existing.groupId,
        'slug': slug.trim(),
        'name': name.trim(),
        'description': description.trim(),
        'image_file_id': existing.imageFileId,
        'sort_order': sortOrder,
        'is_active': isActive,
      },
    );
    return CalcAdminCategory.fromJson(json);
  }

  Future<List<CalcRecipeItem>> recipeItems(String categoryId) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/calculations/recipe-items',
      query: {'category_id': categoryId},
    );
    return (json['items'] as List? ?? const []).cast<Map<String, dynamic>>().map(CalcRecipeItem.fromJson).toList();
  }

  Future<CalcRecipeItem> createRecipeItem(CalcRecipeItemInput input) async {
    final json = await _client.post<Map<String, dynamic>>('/calculations/recipe-items', data: input.toJson());
    return CalcRecipeItem.fromJson(json);
  }

  Future<CalcRecipeItem> updateRecipeItem(String id, CalcRecipeItemInput input) async {
    final json = await _client.put<Map<String, dynamic>>('/calculations/recipe-items/$id', data: input.toJson());
    return CalcRecipeItem.fromJson(json);
  }

  Future<void> deleteRecipeItem(String id) async {
    await _client.delete<dynamic>('/calculations/recipe-items/$id');
  }

  /// Tüm ürün kataloğu (yalnızca `products.read` varsa çağrılır): ilk
  /// sayfadan toplamı öğrenir, kalanları paralel ister -- web
  /// `fetchAllProducts` ile aynı strateji.
  Future<List<CalcProductOption>> allProducts() async {
    Future<({List<CalcProductOption> products, int total})> page(int n) async {
      final json = await _client.get<Map<String, dynamic>>('/products', query: {'limit': productPageSize, 'page': n});
      final products = (json['products'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(CalcProductOption.fromJson)
          .toList();
      return (products: products, total: (json['total'] as num?)?.toInt() ?? products.length);
    }

    final first = await page(1);
    final pages = (first.total / productPageSize).ceil().clamp(1, _maxProductPages);
    if (pages <= 1) return first.products;
    final rest = await Future.wait([for (var n = 2; n <= pages; n++) page(n)]);
    return [...first.products, for (final r in rest) ...r.products];
  }
}

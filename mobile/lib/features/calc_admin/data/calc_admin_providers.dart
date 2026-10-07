import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/calc_admin.dart';
import 'calc_admin_repository.dart';

final calcAdminRepositoryProvider = Provider<CalcAdminRepository>(
  (ref) => CalcAdminRepository(ref.watch(apiClientProvider)),
);

final calcAdminGroupsProvider = FutureProvider.autoDispose<List<CalcAdminGroup>>(
  (ref) => ref.watch(calcAdminRepositoryProvider).groups(),
);

/// Tekil grup ucu olmadığı için liste üzerinden bulunur (liste pasif
/// grupları da içerir); yoksa null.
final calcAdminGroupProvider = FutureProvider.autoDispose.family<CalcAdminGroup?, String>((ref, groupId) async {
  final groups = await ref.watch(calcAdminGroupsProvider.future);
  for (final g in groups) {
    if (g.id == groupId) return g;
  }
  return null;
});

final calcAdminCategoriesProvider = FutureProvider.autoDispose.family<List<CalcAdminCategory>, String>(
  (ref, groupId) => ref.watch(calcAdminRepositoryProvider).categories(groupId),
);

typedef CalcCategoryKey = ({String groupId, String categoryId});

final calcAdminCategoryProvider = FutureProvider.autoDispose.family<CalcAdminCategory?, CalcCategoryKey>((
  ref,
  key,
) async {
  final categories = await ref.watch(calcAdminCategoriesProvider(key.groupId).future);
  for (final c in categories) {
    if (c.id == key.categoryId) return c;
  }
  return null;
});

final calcAdminRecipeItemsProvider = FutureProvider.autoDispose.family<List<CalcRecipeItem>, String>(
  (ref, categoryId) => ref.watch(calcAdminRepositoryProvider).recipeItems(categoryId),
);

/// Grup detay ekranının tek parça verisi (web `fetchGroup` ile aynı iki
/// istek, paralel).
final calcAdminGroupDetailProvider = FutureProvider.autoDispose
    .family<({CalcAdminGroup? group, List<CalcAdminCategory> categories}), String>((ref, groupId) async {
      final results = await Future.wait([
        ref.watch(calcAdminGroupProvider(groupId).future),
        ref.watch(calcAdminCategoriesProvider(groupId).future),
      ]);
      return (group: results[0] as CalcAdminGroup?, categories: results[1] as List<CalcAdminCategory>);
    });

/// Kategori detay ekranının tek parça verisi: kategori + reçete kalemleri.
final calcAdminCategoryDetailProvider = FutureProvider.autoDispose
    .family<({CalcAdminCategory? category, List<CalcRecipeItem> items}), CalcCategoryKey>((ref, key) async {
      final results = await Future.wait([
        ref.watch(calcAdminCategoryProvider(key).future),
        ref.watch(calcAdminRecipeItemsProvider(key.categoryId).future),
      ]);
      return (category: results[0] as CalcAdminCategory?, items: results[1] as List<CalcRecipeItem>);
    });

/// Tüm ürün kataloğu -- YALNIZCA `products.read` olan kullanıcı için
/// izlenir (ekran karar verir). Kategori ekranı ve üstüne açılan kalem
/// formu aynı önbelleği paylaşır.
final calcAdminProductsProvider = FutureProvider.autoDispose<List<CalcProductOption>>(
  (ref) => ref.watch(calcAdminRepositoryProvider).allProducts(),
);

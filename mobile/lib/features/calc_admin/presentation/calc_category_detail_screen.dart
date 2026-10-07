import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/calc_admin_providers.dart';
import '../domain/calc_admin.dart';
import 'calc_admin_common.dart';
import 'calc_node_form_sheet.dart';
import 'calc_node_info_card.dart';
import 'recipe_item_form_screen.dart';

/// Kategori (hesaplama türü) detayı: kategori bilgileri + malzeme reçetesi
/// (web `/admin/metraj-hesaplama/[groupId]/[categoryId]`). Ürün kataloğu
/// AYRI bir izindir (`products.read`) -- yoksa katalog hiç çekilmez, kalemde
/// yalnızca "Bağlı / Bağlı değil" görünür (web ile aynı).
class CalcCategoryDetailScreen extends ConsumerWidget {
  const CalcCategoryDetailScreen({super.key, required this.groupId, required this.categoryId});

  final String groupId;
  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = watchCalcAdminAccess(ref);
    if (!access.canRead) {
      return const AppPageScaffold(title: Text('Metraj Reçeteleri'), body: CalcNoAccessView());
    }

    final key = (groupId: groupId, categoryId: categoryId);
    final detailAsync = ref.watch(calcAdminCategoryDetailProvider(key));
    final productsAsync = access.canReadProducts ? ref.watch(calcAdminProductsProvider) : null;
    final category = detailAsync.valueOrNull?.category;

    // Yenileme göstergesi veri gelene kadar açık kalır (bkz. refreshCalc).
    Future<void> refresh() => refreshCalc(ref, [
      calcAdminCategoriesProvider(groupId),
      calcAdminRecipeItemsProvider(categoryId),
      if (access.canReadProducts) calcAdminProductsProvider,
    ], () => ref.read(calcAdminCategoryDetailProvider(key).future));

    Future<void> editCategory(CalcAdminCategory c) async {
      final repo = ref.read(calcAdminRepositoryProvider);
      final container = ProviderScope.containerOf(context, listen: false);
      var deactivated = false;
      final saved = await showCalcNodeFormSheet(
        context,
        title: 'Kategoriyi Düzenle',
        nameHint: 'ör. 10x10 Petek Tavan',
        nameMaxLength: CalcLimits.categoryName,
        initial: (name: c.name, slug: c.slug, description: c.description, sortOrder: c.sortOrder, isActive: c.isActive),
        onSubmit: (v) async {
          await repo.updateCategory(
            c,
            name: v.name,
            slug: v.slug,
            description: v.description,
            sortOrder: v.sortOrder,
            isActive: v.isActive,
          );
          deactivated = !v.isActive;
          container.invalidate(calcAdminCategoriesProvider(groupId));
        },
      );
      if (!saved || !context.mounted) return;
      // Pasif kategori yönetim listesinde kalır (rozetle) ve buradan
      // yeniden aktifleştirilebilir -- ekran kapatılmaz.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deactivated ? 'Kategori pasifleştirildi; Metraj Hesapla panelinde görünmez.' : 'Kaydedildi.',
          ),
        ),
      );
    }

    Future<void> openItem(CalcRecipeItem? item) async {
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: item == null,
          builder: (_) => RecipeItemFormScreen(categoryId: categoryId, existing: item),
        ),
      );
      if (changed == true) ref.invalidate(calcAdminRecipeItemsProvider(categoryId));
    }

    // Liste tazelemesi silme fonksiyonunun içinde (ekran kapansa da).
    Future<void> deleteItem(CalcRecipeItem item) => confirmAndDeleteRecipeItem(context, ref, item);

    String productLabel(CalcRecipeItem item) {
      final productId = item.productId;
      if (productId == null) return 'Bağlı değil';
      if (productsAsync == null) return 'Bağlı';
      return productsAsync.when(
        data: (products) {
          for (final p in products) {
            if (p.id == productId) return p.name;
          }
          return 'Bağlı ürün (listede yok)';
        },
        loading: () => 'Bağlı (ürün adı yükleniyor…)',
        error: (_, _) => 'Bağlı',
      );
    }

    return AppPageScaffold(
      title: Text(category?.name ?? 'Kategori', maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (access.canManage && category != null)
          IconButton(
            tooltip: 'Düzenle',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => editCategory(category),
          ),
      ],
      floatingActionButton: access.canManage && category != null
          ? FloatingActionButton.extended(
              onPressed: () => openItem(null),
              icon: const Icon(Icons.add),
              label: const Text('Yeni Kalem'),
            )
          : null,
      body: CalcRefreshableAsync(
        value: detailAsync,
        onRefresh: refresh,
        builder: (context, data) {
          final c = data.category;
          if (c == null) {
            return const [
              Padding(
                padding: EdgeInsets.only(top: AppSpacing.xxl),
                child: EmptyStateView(
                  message: 'Kategori bulunamadı.',
                  icon: Icons.search_off_outlined,
                ),
              ),
            ];
          }
          return [
            CalcNodeInfoCard(
              title: 'Kategori Bilgileri',
              name: c.name,
              slug: c.slug,
              description: c.description,
              sortOrder: c.sortOrder,
              isActive: c.isActive,
            ),
            if (!access.canManage) ...[
              const SizedBox(height: AppSpacing.md),
              const ReadOnlyNotice(kCalcReadOnlyMessage),
            ],
            const SizedBox(height: AppSpacing.lg),
            AppSectionHeader(title: 'Malzeme Reçetesi (${data.items.length})'),
            const SizedBox(height: AppSpacing.sm),
            if (data.items.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xl),
                child: EmptyStateView(
                  message: 'Bu kategoride henüz reçete kalemi yok.',
                  icon: Icons.receipt_long_outlined,
                ),
              )
            else
              for (final item in data.items)
                RecipeItemCard(
                  item: item,
                  productLabel: productLabel(item),
                  canManage: access.canManage,
                  onTap: () => openItem(item),
                  onDelete: () => deleteItem(item),
                ),
          ];
        },
      ),
    );
  }
}

/// Reçete kalemi satırı -- web tablosunun sütunları (Malzeme, Birim, Hesap
/// Türü, Katsayı, Fire %, Yuvarlama, Ürün, Durum) dar ekrana üç satırda.
class RecipeItemCard extends StatelessWidget {
  const RecipeItemCard({
    super.key,
    required this.item,
    required this.productLabel,
    required this.canManage,
    required this.onTap,
    required this.onDelete,
  });

  final CalcRecipeItem item;
  final String productLabel;
  final bool canManage;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Türkçe sayı yazımı ("1,05"; Yönetim'in geri kalanıyla aynı).
    final factor = formatCalcNumber(item.activeFactor);
    final waste = formatCalcNumber(item.wastePercent);
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.md),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.xs),
                if (item.groupName.isNotEmpty)
                  Text(item.groupName, style: AppTypography.overline, maxLines: 1, overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.materialName,
                        style: AppTypography.cardTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    calcActiveBadge(item.isActive),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.unit} · ${CalcType.label(item.calculationType)}',
                  style: AppTypography.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'Katsayı $factor · Fire %$waste',
                  style: AppTypography.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // Yuvarlama kuralı kendi satırında -- aynı satırda kesiliyordu.
                const SizedBox(height: 2),
                Text(
                  'Yuvarlama: ${CalcRounding.label(item.roundingType)}',
                  style: AppTypography.metadata,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      item.productId == null ? Icons.link_off : Icons.link,
                      size: 14,
                      color: item.productId == null ? AppColors.textMuted : AppColors.gold,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Ürün: $productLabel',
                        style: AppTypography.metadata.copyWith(color: AppColors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (canManage)
            PopupMenuButton<String>(
              tooltip: 'İşlemler',
              icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
              onSelected: (v) => v == 'delete' ? onDelete() : onTap(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Sil', style: TextStyle(color: AppColors.danger)),
                ),
              ],
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.sm, right: AppSpacing.xs),
              child: Icon(Icons.chevron_right, color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }
}

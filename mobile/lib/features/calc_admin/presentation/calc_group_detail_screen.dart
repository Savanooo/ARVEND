import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/calc_admin_providers.dart';
import '../domain/calc_admin.dart';
import 'calc_admin_common.dart';
import 'calc_node_form_sheet.dart';
import 'calc_node_info_card.dart';

/// Grup detayı: grup bilgileri + hesaplama türleri (kategoriler) listesi
/// (web `/admin/metraj-hesaplama/[groupId]`).
class CalcGroupDetailScreen extends ConsumerWidget {
  const CalcGroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = watchCalcAdminAccess(ref);
    if (!access.canRead) {
      return const AppPageScaffold(title: Text('Metraj Reçeteleri'), body: CalcNoAccessView());
    }

    final detailAsync = ref.watch(calcAdminGroupDetailProvider(groupId));
    final group = detailAsync.valueOrNull?.group;

    Future<void> refresh() => refreshCalc(ref, [
      calcAdminGroupsProvider,
      calcAdminCategoriesProvider(groupId),
    ], () => ref.read(calcAdminGroupDetailProvider(groupId).future));

    Future<void> editGroup(CalcAdminGroup g) async {
      final repo = ref.read(calcAdminRepositoryProvider);
      final container = ProviderScope.containerOf(context, listen: false);
      var deactivated = false;
      final saved = await showCalcNodeFormSheet(
        context,
        title: 'Grubu Düzenle',
        nameHint: 'ör. Petek Tavanlar',
        initial: (name: g.name, slug: g.slug, description: g.description, sortOrder: g.sortOrder, isActive: g.isActive),
        onSubmit: (v) async {
          await repo.updateGroup(
            g.id,
            name: v.name,
            slug: v.slug,
            description: v.description,
            sortOrder: v.sortOrder,
            isActive: v.isActive,
          );
          deactivated = !v.isActive;
          container.invalidate(calcAdminGroupsProvider);
        },
      );
      if (!saved || !context.mounted) return;
      // Pasif grup yönetim listesinde kalır (rozetle) ve buradan yeniden
      // aktifleştirilebilir -- ekran kapatılmaz.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deactivated ? 'Grup pasifleştirildi; Metraj Hesapla panelinde görünmez.' : 'Kaydedildi.',
          ),
        ),
      );
    }

    Future<void> createCategory() async {
      final repo = ref.read(calcAdminRepositoryProvider);
      final container = ProviderScope.containerOf(context, listen: false);
      final created = await showCalcNodeFormSheet(
        context,
        title: 'Yeni Hesaplama Türü (Kategori)',
        nameHint: 'ör. 10x10 Petek Tavan',
        nameMaxLength: CalcLimits.categoryName,
        onSubmit: (v) async {
          await repo.createCategory(groupId: groupId, name: v.name, slug: v.slug, description: v.description);
          container.invalidate(calcAdminCategoriesProvider(groupId));
        },
      );
      if (created) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kategori oluşturuldu.')));
        }
      }
    }

    return AppPageScaffold(
      title: Text(group?.name ?? 'Grup', maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (access.canManage && group != null)
          IconButton(tooltip: 'Düzenle', icon: const Icon(Icons.edit_outlined), onPressed: () => editGroup(group)),
      ],
      floatingActionButton: access.canManage && group != null
          ? FloatingActionButton.extended(
              onPressed: createCategory,
              icon: const Icon(Icons.add),
              label: const Text('Yeni Kategori'),
            )
          : null,
      body: CalcRefreshableAsync(
        value: detailAsync,
        onRefresh: refresh,
        builder: (context, data) {
          final g = data.group;
          if (g == null) {
            return const [
              Padding(
                padding: EdgeInsets.only(top: AppSpacing.xxl),
                child: EmptyStateView(
                  message: 'Grup bulunamadı.',
                  icon: Icons.search_off_outlined,
                ),
              ),
            ];
          }
          return [
            CalcNodeInfoCard(
              title: 'Grup Bilgileri',
              name: g.name,
              slug: g.slug,
              description: g.description,
              sortOrder: g.sortOrder,
              isActive: g.isActive,
            ),
            if (!access.canManage) ...[
              const SizedBox(height: AppSpacing.md),
              const ReadOnlyNotice(kCalcReadOnlyMessage),
            ],
            const SizedBox(height: AppSpacing.lg),
            AppSectionHeader(title: 'Hesaplama Türleri (${data.categories.length})'),
            const SizedBox(height: AppSpacing.sm),
            if (data.categories.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xl),
                child: EmptyStateView(message: 'Bu grupta henüz hesaplama türü yok.', icon: Icons.category_outlined),
              )
            else
              for (final c in data.categories)
                // Pasif kategoriler de listelenir (yalnızca onlar rozetlenir);
                // slug iç veridir -- alt satırda açıklama.
                AppListCard(
                  title: c.name,
                  subtitle: c.description.isEmpty ? null : c.description,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!c.isActive) calcActiveBadge(false),
                      const Icon(Icons.chevron_right, color: AppColors.textMuted),
                    ],
                  ),
                  onTap: () => context.push('$kCalcAdminBasePath/$groupId/${c.id}'),
                ),
          ];
        },
      ),
    );
  }
}

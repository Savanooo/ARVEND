import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/calc_admin_providers.dart';
import 'calc_admin_common.dart';
import 'calc_node_form_sheet.dart';

/// Metraj reçeteleri -- Gruplar (web `/admin/metraj-hesaplama`).
/// Görüntüleme `calculations.read`, yeni grup `calculations.manage`.
class CalcGroupsScreen extends ConsumerWidget {
  const CalcGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = watchCalcAdminAccess(ref);

    if (!access.canRead) {
      return const AppPageScaffold(title: Text('Metraj Reçeteleri'), body: CalcNoAccessView());
    }

    final groupsAsync = ref.watch(calcAdminGroupsProvider);

    Future<void> createGroup() async {
      final repo = ref.read(calcAdminRepositoryProvider);
      // Tazeleme kayıt anında, sayfanın açık kalmasına bağlı olmadan.
      final container = ProviderScope.containerOf(context, listen: false);
      final created = await showCalcNodeFormSheet(
        context,
        title: 'Yeni Hesaplama Grubu',
        nameHint: 'ör. Petek Tavanlar',
        onSubmit: (v) async {
          await repo.createGroup(name: v.name, slug: v.slug, description: v.description);
          container.invalidate(calcAdminGroupsProvider);
        },
      );
      if (created) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Grup oluşturuldu.')));
        }
      }
    }

    return AppPageScaffold(
      title: const Text('Metraj Reçeteleri'),
      floatingActionButton: access.canManage
          ? FloatingActionButton.extended(
              onPressed: createGroup,
              icon: const Icon(Icons.add),
              label: const Text('Yeni Grup'),
            )
          : null,
      body: CalcRefreshableAsync(
        value: groupsAsync,
        onRefresh: () => refreshCalc(ref, [calcAdminGroupsProvider], () => ref.read(calcAdminGroupsProvider.future)),
        builder: (context, groups) => [
          Text(
            'Teklif oluştururken kullanılan hesaplama gruplarını ve altındaki hesaplama türlerini '
            '(kategorileri) buradan ${access.canManage ? 'yönet' : 'görüntüle'}. '
            'Her kategorinin kendi malzeme reçetesi vardır.',
            style: AppTypography.metadata,
          ),
          const SizedBox(height: AppSpacing.md),
          if (!access.canManage) ...[const ReadOnlyNotice(kCalcReadOnlyMessage), const SizedBox(height: AppSpacing.md)],
          if (groups.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xxl),
              child: EmptyStateView(message: 'Henüz hesaplama grubu yok.', icon: Icons.straighten_outlined),
            )
          else
            for (final g in groups)
              // Liste pasif grupları da içerir: yalnızca pasifler rozetlenir
              // (yeniden aktifleştirmek için açılabilir). Slug/sıra iç veridir,
              // detay kartında kalır.
              AppListCard(
                title: g.name,
                subtitle: g.description.isEmpty ? null : g.description,
                leading: Icon(Icons.folder_outlined, color: g.isActive ? AppColors.gold : AppColors.textMuted),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!g.isActive) calcActiveBadge(false),
                    const Icon(Icons.chevron_right, color: AppColors.textMuted),
                  ],
                ),
                onTap: () => context.push('$kCalcAdminBasePath/${g.id}'),
              ),
        ],
      ),
    );
  }
}

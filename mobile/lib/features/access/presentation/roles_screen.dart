import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../access_paths.dart';
import '../data/access_providers.dart';
import 'widgets/access_state_views.dart';

const kRolesNoAccessMessage =
    'Roller & Yetkiler yalnızca Sahip veya Yönetici rolündeki, "Rolleri görüntüleme" izni olan kişilere açıktır.';

const kRolesReadOnlyMessage =
    'Rolleri yalnızca görüntüleyebilirsin; değiştirmek için rolünde "Rolleri ve izinlerini düzenleme" izni olmalı.';

/// Roller & Yetkiler -- web `/admin/roller`. Firmalar yeni rol OLUŞTURAMAZ;
/// yalnızca sistem rollerinin (Sahip/Yönetici/Proje Yöneticisi/Finans/Saha)
/// izin kümesi düzenlenir. "Eski Sistem" rolü backend listesinde yoktur.
class RolesScreen extends ConsumerWidget {
  const RolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('organization.roles.read')) {
      return const AppPageScaffold(
        title: Text('Roller & Yetkiler'),
        body: NoAccessView(message: kRolesNoAccessMessage),
      );
    }
    final canManage = me.canAccess('organization.roles.manage');
    final dataAsync = ref.watch(roleCatalogProvider);

    Future<void> refresh() => refreshAndWait(ref, [
      organizationRolesProvider,
      permissionCatalogProvider,
    ], () => ref.read(roleCatalogProvider.future));

    return AppPageScaffold(
      title: const Text('Roller & Yetkiler'),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: GuardedAsyncView<RoleCatalog>(
          value: dataAsync,
          onRetry: refresh,
          loadingBuilder: (_) => const ListSkeleton(count: 5),
          isEmpty: (d) => d.roles.isEmpty,
          emptyBuilder: (_) => const FillScrollable(
            child: EmptyStateView(message: 'Rol bulunamadı.', icon: Icons.shield_outlined),
          ),
          data: (context, d) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (canManage)
                const InfoNote(
                  'Bir rolün yetkilerini değiştirmek o roldeki herkesi etkiler. Tek bir kişiye özel yetki vermek '
                  'için Personel veya Kullanıcılar ekranını kullan.',
                )
              else
                const ReadOnlyNotice(kRolesReadOnlyMessage),
              const SizedBox(height: AppSpacing.md),
              for (final r in d.roles)
                AppListCard(
                  leading: Icon(
                    r.isOwner ? Icons.workspace_premium_outlined : Icons.shield_outlined,
                    color: AppColors.gold,
                  ),
                  title: r.name,
                  subtitle: r.description.isEmpty ? null : r.description,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (r.isOwner) ...[
                        const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                      StatusBadge(label: '${r.permissions.length} izin', tone: StatusTone.muted),
                    ],
                  ),
                  onTap: () => context.push(AccessPaths.role(r.id)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../data/projects_providers.dart';
import '../contract_co_paths.dart';
import '../data/contract_co_providers.dart';
import 'widgets/change_order_list_card.dart';
import 'widgets/contract_co_ui.dart';
import 'widgets/contract_value_card.dart';

/// "Ek İşler" tam ekranı (`/projeler/:id/ek-isler`) -- gövdesi proje
/// detayının Finans > Ek İşler alt görünümüyle ([ProjectChangeOrdersTab])
/// aynı.
class ProjectChangeOrdersScreen extends StatelessWidget {
  const ProjectChangeOrdersScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(title: const Text('Ek İşler'), body: ProjectChangeOrdersTab(projectId: projectId));
  }
}

/// Proje Ek İşleri listesi (web `ChangeOrdersSection`): sözleşme bedeli
/// kırılımı + ek iş satırları; satır detay ekranını açar. Görmek
/// `projects.finance.read`, "Ek İş Oluştur" `projects.finance.manage`
/// (ek işlerin kendi izni yok). Tamamlanmış/iptal edilmiş projede yeni ek
/// iş oluşturulamaz (sunucu 409, web `locked`).
class ProjectChangeOrdersTab extends ConsumerWidget {
  const ProjectChangeOrdersTab({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (isAuthPending(auth)) return const LoadingState();
    final user = auth.valueOrNull;
    if (!user.can(kChangeOrdersReadPermission)) {
      return const ContractCoNoAccess(message: kChangeOrdersNoAccessText);
    }
    final listAsync = ref.watch(projectChangeOrderListProvider(projectId));
    final summary = ref.watch(contractValueSummaryProvider(projectId)).valueOrNull;
    final project = ref.watch(projectDetailProvider(projectId)).valueOrNull;
    final locked = isProjectLocked(project);
    final canManage = user.can(kChangeOrdersManagePermission);

    Future<void> refresh() async {
      ref.invalidate(projectChangeOrderListProvider(projectId));
      ref.invalidate(contractValueSummaryProvider(projectId));
      try {
        await ref.read(projectChangeOrderListProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    if (listAsync.hasError && isForbiddenError(listAsync.error)) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: const ContractCoNoAccess(message: kChangeOrdersNoAccessText),
      );
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
        children: [
          if (summary != null) ...[ContractValueCard(summary: summary), const SizedBox(height: AppSpacing.lg)],
          AppSectionHeader(
            title: 'Ek İşler',
            trailing: (canManage && !locked)
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Ek İş Oluştur'),
                    onPressed: () => context.push(projectChangeOrderNewPath(projectId)),
                  )
                : null,
          ),
          if (locked) ...[
            const SizedBox(height: AppSpacing.xs),
            const ReadOnlyNotice(kProjectLockedText),
          ] else if (!canManage) ...[
            const SizedBox(height: AppSpacing.xs),
            const ReadOnlyNotice(kChangeOrdersReadOnlyText),
          ],
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: listAsync,
            onRetry: refresh,
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(
              message: 'Henüz ek iş/değişiklik emri yok.',
              icon: Icons.post_add_outlined,
            ),
            data: (context, list) => Column(
              children: [
                for (final co in list)
                  ChangeOrderListCard(
                    changeOrder: co,
                    onTap: () => context.push(projectChangeOrderPath(projectId, co.id)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

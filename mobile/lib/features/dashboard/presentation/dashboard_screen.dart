import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_status_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/metric_card.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/quick_action_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../../customers/presentation/customer_form_sheet.dart';
import '../../notifications/data/notifications_providers.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../../tasks/data/tasks_providers.dart';

/// Backend'de özel bir dashboard/özet ucu YOK (bkz. MOBILE_BACKEND_GAPS.md).
/// Bu ekran yalnızca zaten var olan uçlardan (projeler, görevlerim,
/// bildirim sayacı) minimum sayıda istekle bir özet kurar; hiçbir toplam
/// mobilde yeniden hesaplanmaz, hiçbir yeni backend ucu İCAT EDİLMEZ.
/// "Bugün dikkat gerektirenler" YALNIZCA gecikmiş görevlerdir -- PR/RFQ/PO/
/// taşeron/hakediş onaylarını TEK bir sorguda birleştiren bir backend ucu
/// yok, bu yüzden burada sahte bir "onay bekleyenler" widget'ı İCAT
/// EDİLMEDİ (bkz. redesign denetim raporu, Açık Karar #2).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final activeProjects = ref.watch(projectsListProvider('active'));
    final myTasks = ref.watch(myTasksProvider('open'));
    final unreadCount = ref.watch(unreadNotificationCountProvider).maybeWhen(data: (c) => c, orElse: () => 0);

    final overdueTasks = myTasks.maybeWhen(
      data: (items) => items.where((i) => i.$1.isOverdue).toList(),
      orElse: () => const <ProjectTaskWithProject>[],
    );

    final nameParts = (user?.fullName ?? '').trim().split(RegExp(r'\s+'));
    final firstName = nameParts.isEmpty ? '' : nameParts.first;
    final canCreateOffer = user == null || user.permissions.isEmpty || user.hasPermission('offers.create');
    final canSeeMetraj = user == null || user.permissions.isEmpty || user.hasPermission('calculations.read');
    final canManageCustomers = user == null || user.permissions.isEmpty || user.hasPermission('customers.manage');

    void refreshAll() {
      ref.invalidate(projectsListProvider('active'));
      ref.invalidate(myTasksProvider('open'));
      ref.invalidate(unreadNotificationCountProvider);
    }

    return Scaffold(
      appBar: buildAppBar('Ana Sayfa', actions: [
        IconButton(
          icon: Badge(
            label: Text('$unreadCount'),
            isLabelVisible: unreadCount > 0,
            child: const Icon(Icons.notifications_outlined),
          ),
          tooltip: 'Bildirimler',
          onPressed: () => context.push('/diger/bildirimler'),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: () async => refreshAll(),
        child: ListView(
          padding: kScreenPadding,
          children: [
            Text(
              firstName.isEmpty ? 'Merhaba' : 'Merhaba, $firstName',
              style: AppTypography.pageTitle,
            ),
            if ((user?.organizationName ?? '').isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(user!.organizationName, style: AppTypography.metadata),
            ],
            const SizedBox(height: AppSpacing.lg),
            _BrandDayCard(),
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: 'Bugün'),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: MetricCard(
                    icon: Icons.warning_amber_rounded,
                    label: 'Gecikmiş Görev',
                    value: '${overdueTasks.length}',
                    valueColor: overdueTasks.isNotEmpty ? AppStatusColors.error : null,
                    onTap: () => context.go('/gorevler'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: MetricCard(
                    icon: Icons.notifications_outlined,
                    label: 'Okunmamış Bildirim',
                    value: '$unreadCount',
                    valueColor: unreadCount > 0 ? AppStatusColors.info : null,
                    onTap: () => context.push('/diger/bildirimler'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            AppSectionHeader(
              title: 'Aktif Projeler',
              trailing: TextButton(onPressed: () => context.go('/projeler'), child: const Text('Tümü')),
            ),
            const SizedBox(height: AppSpacing.sm),
            AsyncStateView(
              value: activeProjects,
              onRetry: () async => ref.invalidate(projectsListProvider('active')),
              isEmpty: (r) => r.projects.isEmpty,
              emptyBuilder: (_) => const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: EmptyStateView(message: 'Aktif proje yok.'),
              ),
              data: (context, r) => Column(
                children: r.projects
                    .take(5)
                    .map((p) => _ActiveProjectCard(project: p, onTap: () => context.push('/projeler/${p.id}')))
                    .toList(),
              ),
            ),
            if (overdueTasks.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xl),
              const AppSectionHeader(title: 'Dikkat Gerektirenler'),
              const SizedBox(height: AppSpacing.sm),
              ...overdueTasks.take(4).map((item) {
                final (task, projectId, projectName) = item;
                return _AttentionRow(
                  title: task.title,
                  subtitle: projectName,
                  dueDate: task.dueDate,
                  onTap: () => context.push('/projeler/$projectId/gorevler/${task.id}'),
                );
              }),
            ],
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: 'Hızlı İşlemler'),
            const SizedBox(height: AppSpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (canCreateOffer)
                    QuickActionButton(
                      icon: Icons.description_outlined,
                      label: 'Teklif Oluştur',
                      onPressed: () => context.push('/teklifler/yeni'),
                    ),
                  if (canSeeMetraj) ...[
                    const SizedBox(width: AppSpacing.sm),
                    QuickActionButton(
                      icon: Icons.calculate_outlined,
                      label: 'Metraj Hesapla',
                      onPressed: () => context.push('/diger/metraj'),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.sm),
                  QuickActionButton(
                    icon: Icons.receipt_long_outlined,
                    label: 'Masraf Ekle',
                    onPressed: () => context.go('/projeler'),
                  ),
                  if (canManageCustomers) ...[
                    const SizedBox(width: AppSpacing.sm),
                    QuickActionButton(
                      icon: Icons.person_add_alt_outlined,
                      label: 'Müşteri Ekle',
                      onPressed: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: (sheetContext) => const CustomerFormSheet(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kompakt, kısıtlı bir marka/gün kartı -- büyük bir pazarlama görseli
/// DEĞİL, yalnızca ArvenYapı işareti + bugünün tarihi.
class _BrandDayCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final today = DateFormat('d MMMM yyyy, EEEE', 'tr_TR').format(DateTime.now());
    return AppCard(
      color: AppColors.gold.withValues(alpha: 0.07),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: const Icon(Icons.foundation_outlined, color: AppColors.gold, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ArvenYapı', style: AppTypography.cardTitle),
                Text(today, style: AppTypography.metadata),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveProjectCard extends StatelessWidget {
  const _ActiveProjectCard({required this.project, required this.onTap});
  final Project project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final contractValue = project.currentContractValue ?? project.contractAmount;
    final collected = project.collectedAmount;
    final progress = (collected != null && contractValue > 0) ? (collected / contractValue).clamp(0.0, 1.0) : null;

    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(project.name, style: AppTypography.cardTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      project.customerName.isEmpty ? project.projectNo : project.customerName,
                      style: AppTypography.metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StatusRegistry.build(project.status, StatusRegistry.project),
                  const SizedBox(height: 4),
                  MoneyText(contractValue, currency: project.currency, style: AppTypography.metadata),
                ],
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: AppColors.border,
                valueColor: const AlwaysStoppedAnimation(AppColors.gold),
              ),
            ),
            const SizedBox(height: 2),
            Text('Tahsilat: %${(progress * 100).toStringAsFixed(0)}', style: AppTypography.helper),
          ],
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.title, required this.subtitle, required this.dueDate, required this.onTap});
  final String title;
  final String subtitle;
  final String? dueDate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppStatusColors.error, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  dueDate == null ? subtitle : '$subtitle · ${Formatters.date(dueDate)}',
                  style: AppTypography.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

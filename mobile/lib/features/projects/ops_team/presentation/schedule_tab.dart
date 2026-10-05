import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../../../core/widgets/viz/segment_bar.dart';
import '../data/ops_team_providers.dart';
import '../domain/ops_permissions.dart';
import '../domain/schedule_item.dart';
import '../ops_team_paths.dart';
import 'widgets/ops_common.dart';

/// "Planlama" (iş programı) -- proje detayının Operasyon grubunda bir alt
/// görünüm VE `/projeler/:id/planlama` tam ekranının gövdesi. Web
/// `ScheduleSection` ile aynı veri: aşamalar backend sırasıyla, tarih
/// aralığı, durum, bağlı görev sayısı. Mobilde ek olarak dikey zaman
/// çizelgesi, özet kartı ve GECİKME vurgusu (bitişi geçmiş açık aşama).
///
/// [locked]: proje tamamlandı/iptal (yeni kayıt yok). `null` = proje henüz
/// bilinmiyor -- yazma düğmeleri emin olunana kadar GÖSTERİLMEZ.
class ProjectScheduleTab extends ConsumerWidget {
  const ProjectScheduleTab({
    super.key,
    required this.projectId,
    required this.locked,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  final String projectId;
  final bool? locked;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    // Oturum henüz yüklenmediyse karar verilmez (fail-open bir istek atmasın).
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kProjectOpsReadPermission)) {
      return const NoAccessView(message: kScheduleNoAccessText);
    }
    final canManage = user.can(kProjectOpsManagePermission);
    final canWrite = canManage && locked == false;
    final scheduleAsync = ref.watch(opsScheduleProvider(projectId));
    final today = ref.watch(opsTodayProvider);

    Future<void> refresh() async {
      ref.invalidate(opsScheduleProvider(projectId));
      try {
        await ref.read(opsScheduleProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    if (scheduleAsync.hasError && isOpsForbidden(scheduleAsync.error)) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: const NoAccessView(message: kScheduleNoAccessText, scrollable: true),
      );
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        children: [
          // "Planlama" zaten AppBar'da (tam ekran) ya da seçili çipte yazılı.
          AppSectionHeader(
            title: 'Aşamalar',
            trailing: canWrite
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Aşama Ekle'),
                    onPressed: () => context.push(scheduleNewPath(projectId)),
                  )
                : null,
          ),
          if (locked == true) ...[
            const SizedBox(height: AppSpacing.sm),
            const OpsLockedNotice(),
          ] else if (!canManage) ...[
            const SizedBox(height: AppSpacing.sm),
            const ReadOnlyNotice(kScheduleReadOnlyText),
          ],
          const SizedBox(height: AppSpacing.md),
          AsyncStateView<List<ScheduleItem>>(
            value: scheduleAsync,
            onRetry: refresh,
            isEmpty: (items) => items.isEmpty,
            emptyBuilder: (_) => const OpsEmptyCard('Henüz planlama aşaması yok.', icon: Icons.view_timeline_outlined),
            data: (context, items) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScheduleOverviewCard(overview: ScheduleOverview.of(items, today)),
                const SizedBox(height: AppSpacing.lg),
                for (var i = 0; i < items.length; i++)
                  ScheduleTimelineTile(
                    item: items[i],
                    today: today,
                    isFirst: i == 0,
                    isLast: i == items.length - 1,
                    onTap: () => context.push(scheduleItemPath(projectId, items[i].id)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Aşama sayıları (durum bölüt çubuğu) + geciken sayısı + toplam görev
/// ilerlemesi. Sayıları sunucunun listesinden sayar; hiçbir kayıt
/// değiştirmez.
class ScheduleOverviewCard extends StatelessWidget {
  const ScheduleOverviewCard({super.key, required this.overview});

  final ScheduleOverview overview;

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final taskPct = o.taskTotal > 0 ? o.taskCompleted * 100 / o.taskTotal : null;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('${o.total} aşama', style: AppTypography.cardTitle)),
              if (o.overdue > 0) StatusBadge(label: '${o.overdue} geciken', tone: StatusTone.danger),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppSegmentBar(
            semanticsLabel: 'Aşama durumları',
            segments: [
              for (final s in ScheduleStatus.values)
                SegmentData(label: ScheduleStatus.label(s), value: o.count(s), color: scheduleStatusColor(s)),
            ],
          ),
          if (taskPct != null) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Expanded(child: Text('Görev ilerlemesi', style: AppTypography.metadata)),
                Text(
                  '${o.taskCompleted}/${o.taskTotal} görev',
                  style: AppTypography.metadata.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AppProgressBar(pct: taskPct, color: AppColors.success, semanticsLabel: 'Görev ilerlemesi'),
          ],
        ],
      ),
    );
  }
}

/// Zaman çizelgesindeki tek aşama: solda durum renginde nokta + bağlantı
/// çizgisi, sağda kart (ad, durum, tarih aralığı, süre, gecikme, görev
/// ilerlemesi, açıklamanın ilk satırları).
class ScheduleTimelineTile extends StatelessWidget {
  const ScheduleTimelineTile({
    super.key,
    required this.item,
    required this.today,
    required this.isFirst,
    required this.isLast,
    this.onTap,
  });

  final ScheduleItem item;
  final DateTime today;
  final bool isFirst;
  final bool isLast;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final overdueDays = item.overdueDays(today);
    final overdue = overdueDays > 0;
    final dotColor = overdue ? AppColors.danger : scheduleStatusColor(item.status);
    final duration = item.durationDays;
    final pct = item.taskProgressPct;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(width: 2, height: 18, color: isFirst ? Colors.transparent : AppColors.border),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: item.status == ScheduleStatus.completed ? dotColor : AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 2.5),
                  ),
                ),
                Expanded(child: Container(width: 2, color: isLast ? Colors.transparent : AppColors.border)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppCard(
                onTap: onTap,
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: AppTypography.cardTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        scheduleStatusBadge(item.status),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        const Icon(Icons.event_outlined, size: 14, color: AppColors.textMuted),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            dayRangeText(item.startDate, item.endDate),
                            style: AppTypography.metadata,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (duration != null) Text(' · $duration gün', style: AppTypography.metadata),
                      ],
                    ),
                    if (item.assignedName.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          const Icon(Icons.person_outline, size: 14, color: AppColors.textMuted),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              item.assignedName,
                              style: AppTypography.metadata,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (overdue) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.danger),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Gecikti · bitiş $overdueDays gün önce geçti',
                              style: AppTypography.helper.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (pct != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Expanded(child: AppProgressBar(pct: pct, color: AppColors.success, height: 5)),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            '${item.completedTaskCount}/${item.taskCount} görev',
                            style: AppTypography.helper.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ],
                      ),
                    ],
                    if (item.description.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(item.description, style: AppTypography.helper, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../ops_team/domain/ops_dates.dart';
import '../../ops_team/domain/ops_permissions.dart';
import '../../ops_team/presentation/widgets/ops_common.dart';
import '../daily_report_paths.dart';
import '../data/daily_report_repository.dart';
import '../domain/daily_report.dart';

const kDailyReportNoAccessText =
    'Günlük raporları görüntüleme yetkin yok. Yöneticinden rolüne operasyon görüntüleme yetkisi eklemesini iste.';

/// "Günlük Rapor" -- proje detayının Operasyon grubunda bir alt görünüm VE
/// `/projeler/:id/gunluk-rapor` tam ekranının gövdesi: bugünün raporu
/// (yazılmadıysa "Bugünün raporunu yaz") ve geçmiş raporlar, en yeni gün
/// önce. Satır o günün rapor ekranını açar.
///
/// [locked]: proje tamamlandı/iptal (yeni rapor yok). `null` = proje henüz
/// bilinmiyor -- yazma düğmeleri emin olunana kadar gösterilmez.
class DailyReportsTab extends ConsumerWidget {
  const DailyReportsTab({
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
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kProjectOpsReadPermission)) {
      return const NoAccessView(message: kDailyReportNoAccessText);
    }
    final canWrite = user.can(kProjectOpsManagePermission) && locked == false;
    final async = ref.watch(dailyReportsProvider(projectId));

    Future<void> refresh() async {
      ref.invalidate(dailyReportsProvider(projectId));
      try {
        await ref.read(dailyReportsProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    if (async.hasError && isOpsForbidden(async.error)) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: const NoAccessView(message: kDailyReportNoAccessText, scrollable: true),
      );
    }

    Future<void> open(String date) async {
      await context.push(dailyReportPath(projectId, date));
      ref.invalidate(dailyReportsProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        children: [
          if (locked == true) ...[
            const OpsLockedNotice(),
            const SizedBox(height: AppSpacing.md),
          ],
          AsyncStateView<DailyReportList>(
            value: async,
            onRetry: refresh,
            data: (context, list) {
              final today = list.today.isEmpty ? formatDay(istanbulToday())! : list.today;
              final todays = list.todays;
              final past = list.reports.where((r) => r.reportDate != today).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TodayCard(
                    today: today,
                    report: todays,
                    canWrite: canWrite,
                    onOpen: () => open(today),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppSectionHeader(
                    title: 'Geçmiş Raporlar',
                    trailing: TextButton.icon(
                      key: const ValueKey('gunluk-rapor-gun-sec'),
                      icon: const Icon(Icons.calendar_month_outlined, size: 18),
                      label: const Text('Gün seç'),
                      onPressed: () async {
                        final todayDay = parseDay(today)!;
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: todayDay.subtract(const Duration(days: 1)),
                          firstDate: todayDay.subtract(const Duration(days: 365 * 3)),
                          lastDate: todayDay,
                        );
                        if (picked != null) {
                          await open(formatDay(DateTime.utc(picked.year, picked.month, picked.day))!);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (past.isEmpty)
                    const OpsEmptyCard('Henüz geçmiş rapor yok.', icon: Icons.assignment_outlined)
                  else
                    for (final r in past)
                      DailyReportRow(key: ValueKey('gunluk-rapor-${r.reportDate}'), report: r, onTap: () => open(r.reportDate)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.today, required this.report, required this.canWrite, required this.onOpen});

  final String today;
  final DailyReportListItem? report;
  final bool canWrite;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return AppCard(
      key: const ValueKey('gunluk-rapor-bugun'),
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: r != null || canWrite ? onOpen : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.today_outlined, color: AppColors.gold),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Bugün · ${Formatters.longDate(today)}', style: AppTypography.cardTitle)),
              if (r != null) dailyReportStatusBadge(r.isSubmitted),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (r != null)
            Text(dailyReportSummary(r), style: AppTypography.metadata)
          else if (canWrite) ...[
            const Text('Bugünün raporu henüz yazılmadı.', style: AppTypography.metadata),
            const SizedBox(height: AppSpacing.sm),
            PrimaryButton(
              key: const ValueKey('gunluk-rapor-yaz'),
              label: 'Bugünün Raporunu Yaz',
              icon: Icons.edit_note_outlined,
              onPressed: onOpen,
            ),
          ] else
            const Text('Bugünün raporu henüz yazılmadı.', style: AppTypography.metadata),
        ],
      ),
    );
  }
}

/// Taslak / Gönderildi rozeti.
Widget dailyReportStatusBadge(bool submitted) => submitted
    ? const StatusBadge(label: 'Gönderildi', tone: StatusTone.success)
    : const StatusBadge(label: 'Taslak', tone: StatusTone.muted);

/// "Güneşli 18°C · 9 kişi · 3 fotoğraf".
String dailyReportSummary(DailyReportListItem r) {
  final weather = [
    kDailyReportWeathers[r.weather] ?? '',
    if (r.temperatureC != null) '${r.temperatureC}°C',
  ].where((v) => v.isNotEmpty).join(' ');
  return [
    weather,
    '${r.totalWorkers} kişi',
    if (r.photoCount > 0) '${r.photoCount} fotoğraf',
  ].where((v) => v.isNotEmpty).join(' · ');
}

class DailyReportRow extends StatelessWidget {
  const DailyReportRow({super.key, required this.report, required this.onTap});

  final DailyReportListItem report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            r.weather.isEmpty ? Icons.assignment_outlined : dailyReportWeatherIcon(r.weather),
            color: AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Formatters.longDate(r.reportDate), style: AppTypography.cardTitle),
                Text(dailyReportSummary(r), style: AppTypography.metadata),
                if (r.workDone.isNotEmpty)
                  Text(r.workDone, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.body),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          dailyReportStatusBadge(r.isSubmitted),
        ],
      ),
    );
  }
}

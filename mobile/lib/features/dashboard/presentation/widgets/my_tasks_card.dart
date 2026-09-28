import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../domain/dashboard.dart';
import '../../domain/mobile_routes.dart';
import 'dashboard_nav.dart';
import 'module_card.dart';

/// "Görevlerim" -- finans bölümü olmayan ve bir personel kaydına bağlı
/// kullanıcıda üst sıraya taşınan panel (spec §1.1/§6.4). En çok 5 görev.
class MyTasksCard extends StatelessWidget {
  const MyTasksCard({super.key, required this.data});

  final Dashboard data;

  @override
  Widget build(BuildContext context) {
    final items = data.sections.tasks?.mine.items ?? const <DashMyTask>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(
          title: 'Görevlerim',
          trailing: HeaderLink(label: 'Tümü', onPressed: () => context.go('/gorevler')),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text('Sana atanmış açık görev yok.', style: AppTypography.metadata),
                )
              : Column(
                  children: [
                    for (var i = 0; i < items.length && i < 5; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      MyTaskRow(task: items[i], today: data.today),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// Ana sayfa görev satırının öncelik rozeti. Mobilde gold bir durum rengi
/// DEĞİLDİR (spec D7) ve aciliyeti vade çipi ("Bugün" warning, "{n} gün
/// gecikti" error) taşır; bu yüzden öncelik nötrdür, yalnızca "Acil"
/// danger'dır (web görev satırıyla aynı: yüksek nötr metin, acil kırmızı).
/// Genel `StatusRegistry.taskPriority` görev ekranlarında aynen kalır.
const _kHomeTaskPriority = <String, (String, StatusTone)>{
  'low': ('Düşük', StatusTone.muted),
  'normal': ('Normal', StatusTone.muted),
  'high': ('Yüksek', StatusTone.muted),
  'urgent': ('Acil', StatusTone.danger),
};

/// Tek görev satırı: başlık, proje, vade çipi, öncelik rozeti.
class MyTaskRow extends StatelessWidget {
  const MyTaskRow({super.key, required this.task, required this.today});

  final DashMyTask task;
  final String today;

  Widget? _dueChip() {
    final overdue = task.daysOverdue;
    if (overdue != null && overdue > 0) {
      return StatusBadge(label: '$overdue${kNbsp}gün gecikti', tone: StatusTone.danger);
    }
    final due = task.dueDate;
    if (due == null) return null;
    if (due == today) return const StatusBadge(label: 'Bugün', tone: StatusTone.warning);
    return StatusBadge(label: Formatters.shortDayMonth(due), tone: StatusTone.muted);
  }

  @override
  Widget build(BuildContext context) {
    final chip = _dueChip();
    return CardListRow(
      route: mobileRouteFor(task.ref),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(task.projectName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.helper),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ?chip,
              if (chip != null) const SizedBox(height: 4),
              StatusRegistry.build(task.priority, _kHomeTaskPriority),
            ],
          ),
        ],
      ),
    );
  }
}

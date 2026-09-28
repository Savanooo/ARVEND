import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import 'attention_row.dart';
import 'dashboard_nav.dart';
import 'upcoming_row.dart';

/// "Dikkat Gerektirenler" (spec D10/§6.4): şeritler arası ilk 4 satır --
/// önce Senin sıran, sonra Takipte, sonra Yaklaşan. Her şeridin önünde
/// küçük üst etiket. "Tümü (n)" tam listeyi (/ana-sayfa/dikkat) açar.
class AttentionCard extends StatelessWidget {
  const AttentionCard({super.key, required this.data, this.maxRows = 4});

  final Dashboard data;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final agenda = data.agenda;
    final mine = [
      for (final g in agenda.groups)
        if (g.lane == 'mine') g,
    ];
    final watching = [
      for (final g in agenda.groups)
        if (g.lane == 'watching') g,
    ];
    final upcoming = agenda.upcoming;
    final total = attentionTotal(agenda);
    final partial = data.sectionErrors.isNotEmpty;

    var budget = maxRows;
    List<T> take<T>(List<T> items) {
      final taken = items.take(budget).toList();
      budget -= taken.length;
      return taken;
    }

    final shownMine = take(mine);
    final shownWatching = take(watching);
    final shownUpcoming = take(upcoming);
    final empty = mine.isEmpty && watching.isEmpty && upcoming.isEmpty;

    Widget lane(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 2),
      child: Text(label, style: AppTypography.overline),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeader(
          title: 'Dikkat Gerektirenler',
          trailing: total == 0
              ? null
              : HeaderLink(label: 'Tümü ($total)', onPressed: () => context.push('/ana-sayfa/dikkat')),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (empty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_circle_outline, color: AppStatusColors.success, size: 20),
                      SizedBox(width: AppSpacing.md),
                      Expanded(child: Text(kCopyDikkatEmpty, style: AppTypography.body)),
                    ],
                  ),
                ),
              if (shownMine.isNotEmpty) ...[lane(kLaneMineLabel), for (final g in shownMine) AttentionRow(group: g)],
              if (shownWatching.isNotEmpty) ...[
                lane(kLaneWatchingLabel),
                for (final g in shownWatching) AttentionRow(group: g),
              ],
              if (shownUpcoming.isNotEmpty) ...[
                lane(kLaneUpcomingLabel),
                for (final u in shownUpcoming) UpcomingRow(item: u, today: data.today),
              ],
              if (partial)
                const Padding(
                  padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
                  child: Text(kCopyDikkatPartial, style: AppTypography.helper),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

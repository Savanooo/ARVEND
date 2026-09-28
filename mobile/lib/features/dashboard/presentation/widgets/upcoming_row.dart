import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import '../../domain/mobile_routes.dart';

/// "Yaklaşan · 14 gün" satırı: uyarı renginde takvim ikonu, nötr metin
/// (spec D7), "Bugün" / "Yarın" / "30 Eyl".
class UpcomingRow extends StatelessWidget {
  const UpcomingRow({super.key, required this.item, required this.today});

  final UpcomingItem item;
  final String today;

  @override
  Widget build(BuildContext context) {
    final route = mobileRouteFor(item.ref);
    final meta = [
      upcomingLabel(item.kind),
      upcomingDateLabel(item.date, today),
      if (item.amount != null) Formatters.money(item.amount!.amount, currency: item.amount!.currency),
    ].join(' · ');
    return InkWell(
      onTap: route == null ? null : () => context.push(route),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md + 4 + AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              const Icon(Icons.event_outlined, size: 20, color: AppStatusColors.warning),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.helper),
                  ],
                ),
              ),
              if (route != null) const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

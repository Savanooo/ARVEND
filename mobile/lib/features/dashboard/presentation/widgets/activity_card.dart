import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/event_labels.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../domain/dashboard.dart';
import '../../domain/mobile_routes.dart';
import 'dashboard_nav.dart';
import 'section_error_body.dart';

/// "Son Hareketler" (spec §2 F2/§6.4): en çok 5 satır, TUTAR YOK. Satır
/// proje sayfasını (teklif olayında teklifi) açar. "Tümü" yok. Bölüm o an
/// hesaplanamadıysa başlık kalır, gövde hata satırıdır (spec §6.7).
class ActivityCard extends StatelessWidget {
  const ActivityCard({super.key, required this.data, this.limit = 5, this.onRetry});

  final Dashboard data;
  final int limit;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (data.sections.activity == null && data.sectionErrors.contains('activity')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: 'Son Hareketler'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(child: SectionErrorBody(onRetry: onRetry ?? () {})),
        ],
      );
    }
    final items = (data.sections.activity?.items ?? const <DashActivityItem>[]).take(limit).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: 'Son Hareketler'),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text('Henüz hareket yok.', style: AppTypography.metadata),
                )
              : Column(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                      _ActivityRow(item: items[i], nowIso: data.generatedAt),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.nowIso});

  final DashActivityItem item;
  final String nowIso;

  @override
  Widget build(BuildContext context) {
    final label = eventLabel(item.source, item.eventType);
    final who = item.userName;
    final title = who == null || who.isEmpty ? label : '$who · $label';
    final where = item.source == 'offer'
        ? item.offerNo
        : [item.projectNo, item.projectName].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    final meta = [
      if (where != null && where.isNotEmpty) where,
      Formatters.relative(item.createdAt, nowIso),
    ].join(' · ');
    final route = mobileRouteFor(item.ref);
    return InkWell(
      onTap: route == null ? null : () => openRecordRoute(context, route),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.body),
                  const SizedBox(height: 2),
                  Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.helper),
                ],
              ),
            ),
            if (route != null) const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

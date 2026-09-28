import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/widgets/skeleton_box.dart';
import '../../domain/dashboard_registry.dart';

/// İlk yükleme iskeleti (spec §6.7): sunucunun bölüm kapılarının istemci
/// tahminiyle (`predictSections`) çizilir -- "0" ASLA gösterilmez. İzin
/// kümesi bilinmiyorsa (plan null) genel iskelet: 4 KPI, Dikkat, 4 kart.
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key, required this.plan});

  final Set<String>? plan;

  @override
  Widget build(BuildContext context) {
    final p = plan;
    final int kpiCount;
    final bool secondary;
    final int cardCount;
    final bool registry;
    if (p == null) {
      kpiCount = 4;
      secondary = false;
      cardCount = 4;
      registry = false;
    } else {
      // pickKpis'in olası aday sayısı (bölüm var/yok tahminiyle).
      final candidates =
          (p.contains('finance') ? 3 : 0) +
          (p.contains('offers') ? 1 : 0) +
          (p.contains('projects') ? 1 : 0) +
          (p.contains('tasks') ? 2 : 0) +
          (p.contains('attendance') ? 1 : 0) +
          (p.contains('notifications') ? 1 : 0);
      kpiCount = candidates.clamp(0, 4);
      secondary = p.contains('finance') || p.contains('tasks');
      cardCount = ModuleKey.values.where((m) => !kModules[m]!.isRegistry && p.contains(m.wire)).length;
      registry = ModuleKey.values.any((m) => kModules[m]!.isRegistry && p.contains(m.wire));
    }

    final blocks = <Widget>[
      if (kpiCount >= 2) _KpiSkeleton(count: kpiCount),
      const SkeletonBox(height: 220),
      if (secondary) const SkeletonBox(height: 200),
      for (var i = 0; i < cardCount; i++) const SkeletonBox(height: 200),
      if (registry) const SkeletonBox(height: 180),
    ];
    return Semantics(
      label: 'Yükleniyor',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) SizedBox(height: i == 1 ? AppSpacing.xl : AppSpacing.sm),
            blocks[i],
          ],
        ],
      ),
    );
  }
}

class _KpiSkeleton extends StatelessWidget {
  const _KpiSkeleton({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < count; i += 2) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: AppSpacing.sm));
      rows.add(
        Row(
          children: [
            const Expanded(child: SkeletonBox(height: 96)),
            if (i + 1 < count) ...[
              const SizedBox(width: AppSpacing.sm),
              const Expanded(child: SkeletonBox(height: 96)),
            ],
          ],
        ),
      );
    }
    return Column(children: rows);
  }
}

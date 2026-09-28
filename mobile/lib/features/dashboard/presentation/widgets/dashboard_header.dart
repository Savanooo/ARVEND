import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/skeleton_box.dart';
import '../../../auth/domain/user.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';

/// Karşılama (spec D6/§6.4): "Merhaba, {ad}" (günün saatine göre DEĞİŞMEZ),
/// firma adı AYRI bir Text olarak, sunucunun İstanbul `today`'i + güncelleme
/// saati, özet cümlesi ve (kısıtlı kullanıcıda) kapsam satırı. Veri yokken
/// yalnızca ilk iki satır + iskelet satırı.
class DashboardHeader extends StatelessWidget {
  const DashboardHeader({super.key, required this.user, required this.data, this.loading = false});

  final User? user;
  final Dashboard? data;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final nameParts = (user?.fullName ?? '').trim().split(RegExp(r'\s+'));
    final firstName = nameParts.isEmpty ? '' : nameParts.first;
    final orgName = user?.organizationName ?? '';
    final d = data;
    final scope = d == null ? null : scopeLine(d.viewer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(firstName.isEmpty ? 'Merhaba' : 'Merhaba, $firstName', style: AppTypography.pageTitle),
        if (orgName.isNotEmpty) ...[const SizedBox(height: 2), Text(orgName, style: AppTypography.metadata)],
        if (d != null) ...[
          const SizedBox(height: 2),
          Text(
            '${Formatters.longDate(d.today)} · ${Formatters.hm(d.generatedAt)} güncellendi',
            style: AppTypography.helper,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(summarySentence(d.agenda), style: AppTypography.body),
          if (scope != null) ...[const SizedBox(height: AppSpacing.xs), Text(scope, style: AppTypography.helper)],
        ] else if (loading) ...[
          const SizedBox(height: AppSpacing.sm),
          const SkeletonBox(height: 14, width: 220, radius: 6),
        ],
      ],
    );
  }
}

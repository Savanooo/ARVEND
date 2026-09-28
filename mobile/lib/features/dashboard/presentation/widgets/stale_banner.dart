import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../domain/dashboard_registry.dart';

/// Yenileme başarısız ama eski veri var: veri kalır, üstte uyarı bandı
/// (spec §6.7). Ana sayfa ve Dikkat listesi ortak kullanır.
class StaleBanner extends StatelessWidget {
  const StaleBanner({super.key, required this.generatedAt, required this.onRetry});

  final String generatedAt;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: AppStatusColors.error.withValues(alpha: 0.06),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 18, color: AppStatusColors.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Güncellenemedi · son veri ${Formatters.hm(generatedAt)}',
              style: AppTypography.helper.copyWith(color: AppStatusColors.error),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text(kCopyRetry)),
        ],
      ),
    );
  }
}

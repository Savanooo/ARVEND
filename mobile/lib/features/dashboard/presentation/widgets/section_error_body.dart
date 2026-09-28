import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/dashboard_registry.dart';

/// İzni olan ama sunucunun o an hesaplayamadığı bölüm (section_errors):
/// kart başlığı kalır, gövde bu satırla değişir (spec §6.7).
class SectionErrorBody extends StatelessWidget {
  const SectionErrorBody({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppStatusColors.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.error_outline, size: 18, color: AppStatusColors.error),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(kCopySectionError, style: AppTypography.body.copyWith(color: AppStatusColors.error)),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onRetry, child: const Text(kCopyRetry)),
            ),
          ],
        ),
      ),
    );
  }
}

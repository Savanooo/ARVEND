import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';
import '../../domain/trial_notice.dart';

/// Deneme süresi uyarı bandı (bkz. trialNoticeFor) -- StaleBanner ile aynı
/// dil: tonlu kart + ikon + metin; sağda "bugün için kapat". Bitmek üzere
/// uyarı (sarı), bittiyse hata (kırmızı) tonunda.
class TrialBanner extends StatelessWidget {
  const TrialBanner({super.key, required this.notice, required this.onDismiss});

  final TrialNotice notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = notice.expired ? AppStatusColors.error : AppStatusColors.warning;
    return AppCard(
      key: const ValueKey('trial-banner'),
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
      child: Row(
        children: [
          Icon(notice.expired ? Icons.error_outline : Icons.hourglass_bottom, size: 20, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(notice.text, style: AppTypography.body.copyWith(height: 1.35)),
          ),
          IconButton(
            tooltip: 'Bugün için kapat',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'app_card.dart';

/// Kompakt bir sayı/etiket kutucuğu -- Dashboard'un "Bugün" şeridi ve
/// benzeri özet alanları için. Aynı satırda birkaçı yan yana kullanılmak
/// üzere tasarlandı (bkz. Dashboard).
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: AppColors.gold),
            const SizedBox(height: 8),
          ],
          Text(value, style: AppTypography.metricPrimary.copyWith(color: valueColor)),
          const SizedBox(height: 2),
          Text(label, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

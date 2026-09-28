import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import 'dashboard_nav.dart';

/// Dikkat grubunun tek satırı (spec §6.4): 4dp önem çubuğu, ikon, başlık
/// (en çok 2 satır), alt bilgi ("850.000 TL · en eski 21 gün"). Tek
/// kayıtlı grup doğrudan kaydın ekranını, çoklu grup Dikkat listesini açar.
class AttentionRow extends StatelessWidget {
  const AttentionRow({super.key, required this.group, this.onTap, this.trailing});

  final AttentionGroup group;

  /// Verilmezse varsayılan hedef (attentionGroupTarget) kullanılır.
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final color = severityColor(group.severity);
    final target = attentionGroupTarget(group);
    final tap = onTap ?? (target == null ? null : () => openModuleRoute(context, target));
    final meta = attentionMeta(group);
    return InkWell(
      onTap: tap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: AppSpacing.md),
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(severityIcon(group.severity), size: 20, color: color),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        attentionTitle(group),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(meta, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppTypography.helper),
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (tap != null)
                  const Align(child: Icon(Icons.chevron_right, color: AppColors.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/viz/progress_bar.dart';

class KpiTileData {
  const KpiTileData({
    required this.label,
    required this.value,
    required this.icon,
    required this.semantics,
    this.valueColor,
    this.subs = const [],
    this.progressPct,
    this.progressColor,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;

  /// Ekran okuyucu için TAM değerler (kısa değil).
  final String semantics;

  /// Yalnızca işaretli değerlerde (başarı/hata) -- diğer tüm KPI'lar nötr.
  final Color? valueColor;
  final List<String> subs;
  final double? progressPct;
  final Color? progressColor;
  final VoidCallback? onTap;
}

/// Nabız kutucuğu (spec §6.4 KpiTile): etiket + ikon, büyük değer
/// (sığmazsa küçülür), en çok 2 satır alt bilgi, isteğe bağlı çubuk.
class KpiTile extends StatelessWidget {
  const KpiTile({super.key, required this.data, this.labelMinHeight});

  final KpiTileData data;

  /// Etiket alanının en az yüksekliği. Aynı satırdaki komşu kutucuğun
  /// etiketi 2 satıra sarıyorsa KpiGrid ikisine de 2 satırlık alan verir;
  /// böylece büyük değerler aynı hizada kalır.
  final double? labelMinHeight;

  /// Kutucuğun iç yatay boşluğu + ikon + araları -- etiketin sığacağı
  /// genişliği hesaplamak için (bkz. KpiGrid).
  static const horizontalChrome = 14.0 * 2 + AppSpacing.xs + iconSize;
  static const iconSize = 18.0;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: data.onTap != null,
      label: data.semantics,
      child: ExcludeSemantics(
        child: AppCard(
          onTap: data.onTap,
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 96 - 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: labelMinHeight ?? 0),
                        child: Text(
                          data.label,
                          style: AppTypography.metadata,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(data.icon, size: iconSize, color: AppColors.textMuted),
                  ],
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(data.value, style: AppTypography.metricHero.copyWith(color: data.valueColor)),
                ),
                if (data.progressPct != null) ...[
                  const SizedBox(height: 8),
                  AppProgressBar(pct: data.progressPct, color: data.progressColor ?? AppColors.success),
                ],
                for (final sub in data.subs) ...[
                  const SizedBox(height: 4),
                  Text(sub, style: AppTypography.helper, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../domain/project.dart';

/// Proje/Dashboard listelerinde tekrarlanan tek-bakış proje kartı --
/// isim + müşteri + durum + tutar, artı (yalnızca ZATEN çekilmiş liste
/// verisi -- `currentContractValue`/`collectedAmount` -- yeterliyse) bir
/// tahsilat ilerleme çubuğu. Yeni bir hesap/istek İCAT ETMEZ. Dashboard'un
/// "Aktif Projeler" bölümü ile Proje Listesi ekranı AYNI kartı paylaşır ki
/// ikisi görsel olarak asla birbirinden sapmasın.
class ProjectListCard extends StatelessWidget {
  const ProjectListCard({
    super.key,
    required this.project,
    required this.onTap,
  });
  final Project project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final contractValue =
        project.currentContractValue ?? project.contractAmount;
    final collected = project.collectedAmount;
    final progress = (collected != null && contractValue > 0)
        ? (collected / contractValue).clamp(0.0, 1.0)
        : null;

    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: AppTypography.cardTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      project.customerName.isEmpty
                          ? project.projectNo
                          : project.customerName,
                      style: AppTypography.metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StatusRegistry.build(project.status, StatusRegistry.project),
                  const SizedBox(height: 4),
                  MoneyText(
                    contractValue,
                    currency: project.currency,
                    style: AppTypography.metadata,
                  ),
                ],
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: AppColors.border,
                valueColor: const AlwaysStoppedAnimation(AppColors.gold),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Tahsilat: %${(progress * 100).toStringAsFixed(0)}',
              style: AppTypography.helper,
            ),
          ],
        ],
      ),
    );
  }
}

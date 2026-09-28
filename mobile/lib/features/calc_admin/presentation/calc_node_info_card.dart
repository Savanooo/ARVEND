import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_section_header.dart';
import 'calc_admin_common.dart';

/// Grup / kategori bilgi kartı. Web bu alanları sayfada doğrudan düzenlenebilir
/// form olarak gösterir; mobilde okunaklı bir özet + (izin varsa) üst
/// çubuktaki "Düzenle" ile açılan form sayfası.
class CalcNodeInfoCard extends StatelessWidget {
  const CalcNodeInfoCard({
    super.key,
    required this.title,
    required this.name,
    required this.slug,
    required this.description,
    required this.sortOrder,
    required this.isActive,
  });

  final String title;
  final String name;
  final String slug;
  final String description;
  final int sortOrder;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // "Düzenle" diğer detay ekranlarındaki gibi üst çubukta (kart
          // başlığı salt-okunur haliyle aynı yükseklikte kalır).
          AppSectionHeader(title: title),
          const SizedBox(height: AppSpacing.xs),
          AppDataRow(label: 'Ad', value: name),
          AppDataRow(label: 'Slug', value: slug),
          AppDataRow(label: 'Sıra', value: '$sortOrder'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Durum', style: AppTypography.metadata),
                calcActiveBadge(isActive),
              ],
            ),
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text('Açıklama', style: AppTypography.metadata),
            const SizedBox(height: 2),
            Text(description, style: AppTypography.body),
          ],
        ],
      ),
    );
  }
}

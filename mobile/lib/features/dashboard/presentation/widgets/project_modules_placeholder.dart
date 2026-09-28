import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';

/// Kurulum modunda (yeni firma) projeye bağlı 9 modül kartının yerini
/// tutan tek kart (spec §3.6).
class ProjectModulesPlaceholder extends StatelessWidget {
  const ProjectModulesPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.apartment_outlined, size: 20, color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.md),
              const Expanded(child: Text('Proje modülleri', style: AppTypography.cardTitle)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Proje başladığında finans, ek iş, sözleşme, görev, şantiye, satın alma, taşeron ve bütçe özetleri '
            'burada görünecek.',
            style: AppTypography.body.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    );
  }
}

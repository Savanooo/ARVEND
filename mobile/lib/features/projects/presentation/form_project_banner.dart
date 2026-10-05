import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';

/// Masraf/tahsilat formlarının başında: kaydın HANGİ PROJEYE girildiği.
/// Ana sayfa "Masraf Gir" tek açık proje varken seçiciyi atlayıp formu
/// doğrudan açıyor; başlık yalnızca "Masraf Ekle" iken sahada "nereye
/// giriyorum" sorusu cevapsız kalıyordu (2026-10).
class FormProjectBanner extends StatelessWidget {
  const FormProjectBanner({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('form-proje'),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.business_center_outlined, size: 18, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Proje', style: AppTypography.helper),
                Text(label, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "PRJ-2026-0001 · Proje adı".
String formProjectLabel(String projectNo, String name) =>
    [projectNo, name].where((s) => s.trim().isNotEmpty).join(' · ');

import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Uzun formları (Satın Alma Talebi/RFQ/Sipariş/Taşeron/Hakediş/vb.)
/// "Temel Bilgiler / Ticari Bilgiler / Kalemler / Notlar" gibi mantıksal
/// bölümlere ayırır -- tek, farksız bir sütun yerine. Alanların KENDİSİNİ
/// (TextFormField/dropdown/vb.) içermez, yalnızca gruplama/başlık iskeleti
/// sağlar; her ekran kendi alanlarını `children` olarak geçirir.
class AppFormSection extends StatelessWidget {
  const AppFormSection({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.spacing = AppSpacing.md,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.sectionTitle),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: AppTypography.metadata),
          ],
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: spacing),
            children[i],
          ],
        ],
      ),
    );
  }
}

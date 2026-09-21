import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import 'app_card.dart';

/// Taşeron/Hakediş gibi çok alanlı finansal özetler için -- yan yana N eşit
/// kart yerine, birkaç ÖNE ÇIKAN rakamı (ör. `MetricCard` satırı/`Wrap`ı,
/// `headline`) bir kırılım listesinin (`AppDataRow` listesi, `rows`)
/// ÜSTÜNE ayırır. Hangi rakamların öne çıktığına/kırılımda kaldığına HER
/// EKRAN KENDİSİ karar verir -- burada hiçbir toplam/oran YENİDEN
/// HESAPLANMAZ, yalnızca zaten hesaplanmış widget'lar düzenlenir.
class AppFinancialSummary extends StatelessWidget {
  const AppFinancialSummary({super.key, this.headline, required this.rows});

  final Widget? headline;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (headline != null) ...[headline!, const SizedBox(height: AppSpacing.md), const Divider(), const SizedBox(height: AppSpacing.xs)],
          ...rows,
        ],
      ),
    );
  }
}

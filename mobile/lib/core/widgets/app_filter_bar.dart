import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Tek bir filtre çipi -- etiket/seçili/aksiyon. `AppFilterBar`'ın veri
/// modeli, tek tek `ChoiceChip`/`FilterChip` inşa etmenin yerini alır.
class AppFilterChipData {
  const AppFilterChipData({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

/// Proje/Teklif/Müşteri/Görev listelerinde tekrarlanan filtre çipi
/// satırı. Varsayılan (`wrap: false`) yatay kaydırmalı tek satır --
/// durum sekmeleri gibi TEK seçilebilir, sayıca sınırsız filtreler için.
/// `wrap: true`, birden çok çipin AYNI ANDA seçili olabildiği (ör. görev
/// önceliği + "yalnızca gecikmiş") durumlar için satır satır sarar.
class AppFilterBar extends StatelessWidget {
  const AppFilterBar({super.key, required this.chips, this.wrap = false});

  final List<AppFilterChipData> chips;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    if (wrap) {
      return Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [for (final c in chips) _buildChip(c)],
      );
    }
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (_, i) => _buildChip(chips[i]),
      ),
    );
  }

  Widget _buildChip(AppFilterChipData c) => FilterChip(
    label: Text(c.label),
    selected: c.selected,
    onSelected: (_) => c.onTap(),
  );
}

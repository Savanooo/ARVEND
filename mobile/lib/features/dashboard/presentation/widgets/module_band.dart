import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/dashboard_registry.dart';
import 'module_card.dart';
import 'module_cards.dart';
import 'project_modules_placeholder.dart';
import 'records_group_card.dart';

/// Bir bant: büyük harfli üst etiket + kartlar (mobilde tam genişlik,
/// satır başına bir kart). FİRMA KAYITLARI modülleri tek gruplu kartta
/// toplanır; yoğun modda ("BÖLÜMLER") onlar da bandın sonunda gruplanır.
class ModuleBand extends StatelessWidget {
  const ModuleBand({super.key, required this.band, required this.cardContext});

  final LayoutBand band;
  final DashCardContext cardContext;

  @override
  Widget build(BuildContext context) {
    final standard = [
      for (final m in band.all)
        if (!kModules[m]!.isRegistry) m,
    ];
    final registry = [
      for (final m in band.all)
        if (kModules[m]!.isRegistry) m,
    ];
    final cards = <Widget>[
      if (band.placeholder) const ProjectModulesPlaceholder(),
      for (final m in standard) buildModuleCard(m, cardContext),
      if (registry.isNotEmpty) RecordsGroupCard(modules: registry, cardContext: cardContext),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(band.title, style: AppTypography.overline),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < cards.length; i++) ...[if (i > 0) const SizedBox(height: AppSpacing.sm), cards[i]],
      ],
    );
  }
}

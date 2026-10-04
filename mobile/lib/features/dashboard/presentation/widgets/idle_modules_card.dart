import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/dashboard_registry.dart';
import 'dashboard_nav.dart';

/// Sayfa sonunda tek satır: kartı çizilmeyen boş modüller (bkz.
/// moduleIdle). Her ad kendi ekranını açar -- boş modül gizlenir ama
/// ulaşılamaz olmaz.
class IdleModulesCard extends StatelessWidget {
  const IdleModulesCard({super.key, required this.modules});

  final List<ModuleKey> modules;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('bos-moduller'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('HENÜZ KULLANILMAYAN BÖLÜMLER', style: AppTypography.overline),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final m in modules)
              if (kModules[m] case final def?)
                ActionChip(
                  avatar: Icon(def.icon, size: 16, color: AppColors.textMuted),
                  label: Text(def.title),
                  labelStyle: AppTypography.metadata,
                  side: const BorderSide(color: AppColors.border),
                  backgroundColor: AppColors.surface,
                  onPressed: def.route == null ? null : () => openModuleRoute(context, def.route!),
                ),
          ],
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../auth/domain/user.dart';

class _Shortcut {
  const _Shortcut(this.label, this.icon, this.path, {this.push = false, this.permission});
  final String label;
  final IconData icon;
  final String path;
  final bool push;
  final String? permission;
}

const _shortcuts = <_Shortcut>[
  _Shortcut('Projeler', Icons.business_outlined, '/projeler'),
  _Shortcut('Teklifler', Icons.description_outlined, '/teklifler', permission: 'offers.read'),
  _Shortcut('Görevler', Icons.checklist_outlined, '/gorevler', permission: 'projects.tasks.read'),
  _Shortcut('Müşteriler', Icons.people_outline, '/diger/musteriler', push: true, permission: 'customers.read'),
  _Shortcut('Mesai', Icons.schedule, '/diger/mesai', push: true, permission: 'attendance.read'),
  _Shortcut('Metraj', Icons.straighten, '/diger/metraj', push: true, permission: 'calculations.read'),
  _Shortcut(
    'Bildirimler',
    Icons.notifications_outlined,
    '/diger/bildirimler',
    push: true,
    permission: 'notifications.read',
  ),
];

/// Özet hiç yüklenemediğinde modüllere giden kısayollar (spec §6.7):
/// görünen sekmeler + Diğer girdileri, izinle süzülmüş.
class ShortcutsGrid extends StatelessWidget {
  const ShortcutsGrid({super.key, required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final s in _shortcuts)
        if (s.permission == null || user.can(s.permission!)) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: 'Kısayollar'),
        const SizedBox(height: AppSpacing.sm),
        LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 300 && MediaQuery.textScalerOf(context).scale(1) < 1.3;
            final width = twoColumns ? (constraints.maxWidth - AppSpacing.sm) / 2 : constraints.maxWidth;
            return Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final s in items)
                  SizedBox(
                    width: width,
                    child: AppCard(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                      onTap: () => s.push ? context.push(s.path) : context.go(s.path),
                      child: Row(
                        children: [
                          Icon(s.icon, size: 20, color: AppColors.textMuted),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(child: Text(s.label, style: AppTypography.body)),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

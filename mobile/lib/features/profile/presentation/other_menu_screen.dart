import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../auth/domain/user.dart';

class OtherMenuScreen extends ConsumerWidget {
  const OtherMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    // RBAC/Project Membership sprint'i: permissions boşsa (nadir, henüz
    // yüklenmemiş) HİÇBİR öğe izin kontrolüyle gizlenmez -- backend zaten
    // 403 üretir, burada yalnızca UX'tir (spec: "hide inaccessible nav
    // items"). owner/admin/legacy_user TÜM izinlere sahip olduğu için bu
    // kontroller onlar için hiçbir zaman bir şey gizlemez.
    final noPermissionData = user == null || user.permissions.isEmpty;
    bool canSee(String code) => noPermissionData || user.hasPermission(code);

    final toolItems = [
      if (canSee('customers.read'))
        _MenuItem(
          icon: Icons.people_outline,
          label: 'Müşteriler',
          onTap: () => context.push('/diger/musteriler'),
        ),
      if (canSee('calculations.read'))
        _MenuItem(
          icon: Icons.straighten_outlined,
          label: 'Metraj Hesaplama',
          onTap: () => context.push('/diger/metraj'),
        ),
      if (canSee('attendance.read'))
        _MenuItem(
          icon: Icons.access_time_outlined,
          label: 'Mesai',
          onTap: () => context.push('/diger/mesai'),
        ),
    ];

    final accountItems = [
      _MenuItem(
        icon: Icons.person_outline,
        label: 'Profil',
        onTap: () => context.push('/diger/profil'),
      ),
      if (canSee('notifications.read'))
        _MenuItem(
          icon: Icons.notifications_outlined,
          label: 'Bildirimler',
          onTap: () => context.push('/diger/bildirimler'),
        ),
      _MenuItem(
        icon: Icons.info_outline,
        label: 'Hakkında',
        onTap: () => context.push('/diger/hakkinda'),
      ),
    ];

    // Firma Ayarları backend'de requireAdmin arkasındadır (bkz. router.go:
    // /organization/settings/*) -- kullanici rolüne 403 ile sonuçlanacak
    // bir ekranı göstermemek için yalnızca admin'e gösterilir (Super Admin
    // mobilde bu ekranı kullanmaz, bkz. MOBILE_BACKEND_GAPS.md - platform
    // yönetimi web'e özeldir).
    final managementItems = [
      if (user?.role == UserRole.admin)
        _MenuItem(
          icon: Icons.apartment_outlined,
          label: 'Firma Ayarları',
          onTap: () => context.push('/diger/firma-ayarlari'),
        ),
    ];

    return Scaffold(
      appBar: buildAppBar('Diğer'),
      body: ListView(
        padding: kScreenPadding,
        children: [
          if (toolItems.isNotEmpty) ...[
            const AppSectionHeader(title: 'İş Araçları'),
            const SizedBox(height: AppSpacing.sm),
            for (final item in toolItems) _MenuTile(item: item),
            const SizedBox(height: AppSpacing.md),
          ],
          const AppSectionHeader(title: 'Hesap'),
          const SizedBox(height: AppSpacing.sm),
          for (final item in accountItems) _MenuTile(item: item),
          if (managementItems.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            const AppSectionHeader(title: 'Yönetim'),
            const SizedBox(height: AppSpacing.sm),
            for (final item in managementItems) _MenuTile(item: item),
          ],
        ],
      ),
    );
  }
}

class _MenuItem {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.item});
  final _MenuItem item;

  @override
  Widget build(BuildContext context) {
    return AppListCard(
      title: item.label,
      leading: Icon(item.icon, color: AppColors.gold),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
      onTap: item.onTap,
    );
  }
}

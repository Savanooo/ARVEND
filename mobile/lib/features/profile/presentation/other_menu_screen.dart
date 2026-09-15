import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
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

    return Scaffold(
      appBar: buildAppBar('Diğer'),
      body: ListView(
        padding: kScreenPadding,
        children: [
          if (canSee('calculations.read'))
            _MenuTile(icon: Icons.straighten_outlined, label: 'Metraj Hesaplama', onTap: () => context.push('/diger/metraj')),
          if (canSee('customers.read'))
            _MenuTile(icon: Icons.people_outline, label: 'Müşteriler', onTap: () => context.push('/diger/musteriler')),
          if (canSee('attendance.read'))
            _MenuTile(icon: Icons.access_time_outlined, label: 'Mesai', onTap: () => context.push('/diger/mesai')),
          // Firma Ayarları backend'de requireAdmin arkasındadır (bkz.
          // router.go: /organization/settings/*) -- kullanici rolüne 403
          // ile sonuçlanacak bir ekranı göstermemek için yalnızca admin'e
          // gösterilir (Super Admin mobilde bu ekranı kullanmaz, bkz.
          // MOBILE_BACKEND_GAPS.md - platform yönetimi web'e özeldir).
          if (user?.role == UserRole.admin)
            _MenuTile(
              icon: Icons.apartment_outlined,
              label: 'Firma Ayarları',
              onTap: () => context.push('/diger/firma-ayarlari'),
            ),
          _MenuTile(icon: Icons.person_outline, label: 'Profil', onTap: () => context.push('/diger/profil')),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: AppColors.gold),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: onTap,
      ),
    );
  }
}

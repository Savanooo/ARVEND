import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';

/// ARVEND Mobile bir KİRACI (tenant) uygulamasıdır -- `super_admin` bir
/// organizasyona bağlı değildir ve platform yönetimi mobilde HİÇ YOKTUR
/// (bkz. app_router.dart `_forcedRouteFor`: super_admin için BAŞKA HER
/// kontrolden ÖNCE, koşulsuz olarak buraya yönlendirilir). Bu ekran hiçbir
/// kiracı API'sini ÇAĞIRMAZ -- yalnızca oturumda zaten bulunan kullanıcı
/// adını gösterir ve çıkış sağlar.
class SuperAdminUnsupportedScreen extends ConsumerWidget {
  const SuperAdminUnsupportedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.navDark,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.admin_panel_settings_outlined, color: AppColors.gold, size: 32),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    'Bu hesap platform yönetimi içindir. Yönetim panelini web üzerinden kullanın.',
                    style: AppTypography.sectionTitle,
                    textAlign: TextAlign.center,
                  ),
                  if (user != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Hesap: ${user.username}',
                      style: AppTypography.metadata,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  SecondaryButton(
                    label: 'Çıkış Yap',
                    onPressed: () => ref.read(authControllerProvider.notifier).logout(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

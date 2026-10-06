import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';

/// Firma kurulumu (onboarding) bitmemiş bir firmanın YÖNETİCİ OLMAYAN
/// kullanıcısı. Kurulum uçları yalnızca kaba rol `admin`e açık (backend
/// `requireAdmin`), iş uçları ise kurulum bitene kadar 403 döner -- bu
/// kişinin yapabileceği hiçbir şey yok. Eskiden kurulum sihirbazına
/// yönlendiriliyordu: yalnızca hata + "Tekrar Dene" görüp çıkış da
/// yapamadan kilitli kalıyordu (bkz. app_router.dart `_forcedRouteFor`).
class OnboardingPendingScreen extends ConsumerStatefulWidget {
  const OnboardingPendingScreen({super.key});

  @override
  ConsumerState<OnboardingPendingScreen> createState() => _OnboardingPendingScreenState();
}

class _OnboardingPendingScreenState extends ConsumerState<OnboardingPendingScreen> {
  bool _checking = false;

  /// Sahip kurulumu bitirdiyse kullanıcı tazelenince router ana sayfaya
  /// çıkarır; bitmediyse bu ekran kalır.
  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await ref.read(authControllerProvider.notifier).refresh();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    child: const Icon(Icons.hourglass_top_outlined, color: AppColors.gold, size: 32),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    'Firma kurulumu henüz tamamlanmadı; firma sahibinin kurulumu bitirmesi gerekiyor.',
                    style: AppTypography.sectionTitle,
                    textAlign: TextAlign.center,
                  ),
                  if (user != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      [if (user.organizationName.isNotEmpty) user.organizationName, 'Hesap: ${user.username}'].join(' · '),
                      style: AppTypography.metadata,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  PrimaryButton(
                    label: 'Tekrar Kontrol Et',
                    loading: _checking,
                    onPressed: _checking ? null : _check,
                  ),
                  const SizedBox(height: AppSpacing.sm),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';

/// Organizasyon askıya alınmış/iptal edilmiş/silinmiş durumdayken (bkz.
/// AccountAccessIssue.organizationBlocked, backend üçünü de AYNI sabit
/// mesajla döndüğü için mobil bunları AYIRT ETMEZ) gösterilir. Bu ekran
/// hiçbir kiracı API'sini ÇAĞIRMAZ -- yalnızca çıkışa izin verir; oturum
/// zaten ApiClient._notifyAccountAccessBlocked tarafından temizlenmiştir,
/// bu yüzden "yeniden dene" YOKTUR (backend'e karşı istek fırtınası riski
/// oluşturmaz).
class AccountAccessBlockedScreen extends ConsumerWidget {
  const AccountAccessBlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                      color: AppColors.danger.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.lock_outline, color: AppColors.danger, size: 32),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    'Firmanızın platform erişimi şu anda kapalı.',
                    style: AppTypography.sectionTitle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Bilgi için firma yöneticinizle veya ARVEND destek ekibiyle iletişime geçin.',
                    style: AppTypography.body,
                    textAlign: TextAlign.center,
                  ),
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

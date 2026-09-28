import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../../auth/domain/user.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';

/// "Kurulum — ilk adımlar" (spec §3.6): yeni firmada Nabız ve üst sıranın
/// yerine. "done" sunucudan gelir. CTA'lar web `ONBOARDING_STEPS` ile aynı
/// hedef ve kapıdadır; katalog/personel/ekip adımları mobildeki yönetim
/// ekranlarını açar (katı `canAccess`, bkz. AdminCta).
class OnboardingCard extends StatelessWidget {
  const OnboardingCard({
    super.key,
    required this.onboarding,
    required this.user,
    required this.onHide,
    required this.onQuickAction,
  });

  final DashboardOnboarding onboarding;
  final User? user;
  final VoidCallback onHide;
  final void Function(QuickActionKey action) onQuickAction;

  ({String label, VoidCallback onTap})? _cta(BuildContext context, String key) {
    switch (key) {
      case 'customer':
        return user.can('customers.manage')
            ? (label: 'Müşteri Ekle', onTap: () => onQuickAction(QuickActionKey.customer))
            : null;
      case 'first_offer':
        return user.can('offers.create')
            ? (label: 'Yeni Teklif', onTap: () => onQuickAction(QuickActionKey.offer))
            : null;
      case 'convert':
        return user.can('offers.read') ? (label: 'Tekliflere git', onTap: () => context.go('/teklifler')) : null;
      case 'catalog':
        return _admin(context, kCtaProducts);
      case 'employee':
        return _admin(context, kCtaAddEmployee);
      case 'team':
        return _admin(context, kCtaAddUser);
      default:
        return null;
    }
  }

  ({String label, VoidCallback onTap})? _admin(BuildContext context, AdminCta cta) =>
      cta.allowedFor(user) ? (label: cta.label, onTap: () => context.push(cta.route)) : null;

  @override
  Widget build(BuildContext context) {
    final total = onboarding.total;
    final done = onboarding.doneCount;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Kurulum — ilk adımlar', style: AppTypography.cardTitle)),
              TextButton(onPressed: onHide, child: const Text('Gizle')),
            ],
          ),
          Text('$done / $total tamamlandı', style: AppTypography.helper),
          const SizedBox(height: AppSpacing.sm),
          AppProgressBar(
            pct: total == 0 ? 0 : done / total * 100,
            color: AppColors.gold,
            semanticsLabel: 'Kurulum $done / $total tamamlandı',
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final step in onboarding.steps) _StepRow(step: step, cta: step.done ? null : _cta(context, step.key)),
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => context.push('/diger/firma-ayarlari'),
              child: const Text('Firma bilgilerini gözden geçir →'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.cta});

  final OnboardingStep step;
  final ({String label, VoidCallback onTap})? cta;

  @override
  Widget build(BuildContext context) {
    final copy = kOnboardingSteps[step.key] ?? OnboardingStepCopy(step.key);
    final detail = step.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            step.done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: step.done ? AppStatusColors.success : AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  copy.title,
                  style: step.done
                      ? AppTypography.body.copyWith(color: AppColors.textMuted)
                      : AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                ),
                if (step.done && detail != null && detail.isNotEmpty)
                  Text(detail, style: AppTypography.helper)
                else if (!step.done && copy.helper != null)
                  Text(copy.helper!, style: AppTypography.helper),
                if (cta != null)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                    onPressed: cta!.onTap,
                    child: Text(cta!.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Gizle"den sonra üstte kalan tek satır: rehber geri açılabilir.
class OnboardingHiddenBar extends StatelessWidget {
  const OnboardingHiddenBar({super.key, required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Row(
        children: [
          const Expanded(child: Text('Kurulum rehberi gizlendi', style: AppTypography.helper)),
          TextButton(onPressed: onShow, child: const Text('Göster')),
        ],
      ),
    );
  }
}

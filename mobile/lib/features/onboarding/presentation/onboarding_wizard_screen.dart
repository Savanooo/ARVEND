import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/onboarding_providers.dart';
import '../domain/onboarding_state.dart';
import 'onboarding_step_forms.dart';

const _kStepTitles = ['Firma', 'Resmi / Fatura', 'Teklif', 'Finans', 'İşletme'];

/// İlk-giriş onboarding sihirbazı (5 adım, ARVEND — SUPER ADMIN + FİRMA
/// YÖNETİMİ fazı). Yeni provision edilmiş bir organizasyonun Owner'ı,
/// onboarding_completed=false olduğu sürece (ve must_change_password
/// akışını geçtikten SONRA) bu ekrana yönlendirilir (bkz. app_router.dart).
/// Server-authoritative: adım GET /onboarding/'den okunur (web ile AYNI
/// state), her "İleri" gerçek bir PUT çağrısıdır -- yerel state yalnızca
/// hangi adımın GÖSTERİLDİĞİNİ tutar, hangi adımın TAMAMLANDIĞINI değil.
class OnboardingWizardScreen extends ConsumerStatefulWidget {
  const OnboardingWizardScreen({super.key});

  @override
  ConsumerState<OnboardingWizardScreen> createState() => _OnboardingWizardScreenState();
}

class _OnboardingWizardScreenState extends ConsumerState<OnboardingWizardScreen> {
  OnboardingState? _state;
  Object? _loadError;
  int _visibleStep = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await ref.read(onboardingRepositoryProvider).getState();
      if (!mounted) return;
      setState(() {
        _state = state;
        _visibleStep = onboardingStepIndex(state.onboardingStep).clamp(0, 4);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  void _onStepSaved(OnboardingState newState) {
    setState(() {
      _state = newState;
      if (newState.onboardingCompleted) return;
      final nextIndex = onboardingStepIndex(newState.onboardingStep).clamp(0, 4);
      // Forward-only: sunucu hiçbir zaman geri gitmez, yerelde de geri
      // gitmeyiz -- yalnızca ilerisi gösterilebilir bir adımsa atlarız.
      _visibleStep = nextIndex > _visibleStep ? nextIndex : _visibleStep + 1;
      if (_visibleStep > 4) _visibleStep = 4;
    });
    if (newState.onboardingCompleted) {
      // must_change_password/onboarding gibi User alanlarını tazele ki
      // router redirect zinciri bu ekrandan çıksın.
      ref.read(authControllerProvider.notifier).refresh();
    }
  }

  Widget? _backButton() {
    if (_visibleStep == 0) return null;
    return SecondaryButton(
      label: 'Geri',
      onPressed: () => setState(() => _visibleStep -= 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return AppPageScaffold(
      title: const Text('Firma Kurulumu'),
      // Bu ekranın uygulamaya dönecek bir geri navigasyonu YOK -- yalnızca
      // adımlar arası sihirbaz "Geri" düğmesi var.
      automaticallyImplyLeading: false,
      body: state == null
          ? (_loadError != null ? ErrorState(error: _loadError!, onRetry: _load) : const LoadingState())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                _StepIndicator(currentIndex: _visibleStep),
                const SizedBox(height: AppSpacing.xl),
                Text(_kStepTitles[_visibleStep], style: AppTypography.sectionTitle),
                const SizedBox(height: AppSpacing.xs),
                Text('Adım ${_visibleStep + 1} / 5', style: AppTypography.metadata),
                const SizedBox(height: AppSpacing.lg),
                _buildStep(state),
              ],
            ),
    );
  }

  Widget _buildStep(OnboardingState state) {
    final repo = ref.read(onboardingRepositoryProvider);
    switch (_visibleStep) {
      case 0:
        return CompanyStepForm(
          repository: repo,
          initial: state.profile,
          onSaved: _onStepSaved,
          submitLabel: 'İleri',
        );
      case 1:
        return BillingStepForm(
          repository: repo,
          initial: state.profile,
          onSaved: _onStepSaved,
          submitLabel: 'İleri',
          leading: _backButton(),
        );
      case 2:
        return OffersStepForm(
          repository: repo,
          initial: state.commercial,
          onSaved: _onStepSaved,
          submitLabel: 'İleri',
          leading: _backButton(),
        );
      case 3:
        return FinanceStepForm(
          repository: repo,
          initial: state.commercial,
          onSaved: _onStepSaved,
          submitLabel: 'İleri',
          leading: _backButton(),
        );
      case 4:
      default:
        return BusinessStepForm(
          repository: repo,
          initial: state.profile,
          onSaved: _onStepSaved,
          submitLabel: 'Tamamla',
          leading: _backButton(),
        );
    }
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.currentIndex});
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(_kStepTitles.length, (i) {
        final active = i <= currentIndex;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i == _kStepTitles.length - 1 ? 0 : AppSpacing.xs),
            height: AppSpacing.xs,
            decoration: BoxDecoration(
              color: active ? AppColors.gold : AppColors.border,
              borderRadius: BorderRadius.circular(AppRadius.badge),
            ),
          ),
        );
      }),
    );
  }
}

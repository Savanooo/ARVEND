import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
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
  String? _loadError;
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = 'Kurulum bilgileri yüklenemedi. Lütfen tekrar deneyin.');
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
    return OutlinedButton(
      onPressed: () => setState(() => _visibleStep -= 1),
      child: const Text('Geri'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('Firma Kurulumu'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: state == null
            ? Center(
                child: _loadError != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_loadError!, style: const TextStyle(color: AppColors.danger), textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            ElevatedButton(onPressed: _load, child: const Text('Tekrar Dene')),
                          ],
                        ),
                      )
                    : const CircularProgressIndicator(),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _StepIndicator(currentIndex: _visibleStep),
                  const SizedBox(height: 24),
                  Text(_kStepTitles[_visibleStep], style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                  const SizedBox(height: 4),
                  Text('Adım ${_visibleStep + 1} / 5', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  const SizedBox(height: 20),
                  _buildStep(state),
                ],
              ),
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
            margin: EdgeInsets.only(right: i == _kStepTitles.length - 1 ? 0 : 6),
            height: 4,
            decoration: BoxDecoration(
              color: active ? AppColors.gold : AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

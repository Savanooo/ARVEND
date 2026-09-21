import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/onboarding_providers.dart';
import '../domain/onboarding_state.dart';
import 'onboarding_step_forms.dart';

/// Onboarding SONRASI "Firma Ayarları" düzenleme ekranı -- Diğer menüsünden
/// erişilir. AYNI 5 adım formunu (onboarding_step_forms.dart) kullanır,
/// AYNI backend state'ini okur/yazar (organizations.onboarding_step/
/// onboarding_completed + organization_profile/organization_commercial_
/// settings) ama /organization/settings/* uçları üzerinden -- sihirbazın
/// aksine, sekmeler arasında SERBEST gezinilir (zorunlu ileri/geri yok),
/// her sekme kendi "Kaydet" düğmesiyle bağımsız kaydedilir (project_detail_
/// screen.dart'taki DefaultTabController/TabBar deseniyle AYNI).
class OrganizationSettingsScreen extends ConsumerStatefulWidget {
  const OrganizationSettingsScreen({super.key});

  @override
  ConsumerState<OrganizationSettingsScreen> createState() => _OrganizationSettingsScreenState();
}

class _OrganizationSettingsScreenState extends ConsumerState<OrganizationSettingsScreen> {
  OnboardingState? _state;
  Object? _loadError;
  String? _savedMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final state = await ref.read(organizationSettingsRepositoryProvider).getState();
      if (!mounted) return;
      setState(() => _state = state);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  void _onSaved(OnboardingState newState) {
    setState(() {
      _state = newState;
      _savedMessage = 'Kaydedildi.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return DefaultTabController(
      length: 5,
      child: AppPageScaffold(
        title: const Text('Firma Ayarları'),
        bottom: const TabBar(
          isScrollable: true,
          tabs: [
            Tab(text: 'Firma'),
            Tab(text: 'Resmi / Fatura'),
            Tab(text: 'Teklif'),
            Tab(text: 'Finans'),
            Tab(text: 'İşletme'),
          ],
        ),
        body: state == null
            ? (_loadError != null ? ErrorState(error: _loadError!, onRetry: _load) : const LoadingState())
            : Column(
                children: [
                  if (_savedMessage != null)
                    Container(
                      width: double.infinity,
                      color: AppColors.success.withValues(alpha: 0.1),
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text(_savedMessage!,
                          textAlign: TextAlign.center,
                          style: AppTypography.body.copyWith(color: AppColors.success)),
                    ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _tabPadding(CompanyStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.profile,
                          onSaved: _onSaved,
                        )),
                        _tabPadding(BillingStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.profile,
                          onSaved: _onSaved,
                        )),
                        _tabPadding(OffersStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.commercial,
                          onSaved: _onSaved,
                        )),
                        _tabPadding(FinanceStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.commercial,
                          onSaved: _onSaved,
                        )),
                        _tabPadding(BusinessStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.profile,
                          onSaved: _onSaved,
                          submitLabel: 'Kaydet',
                        )),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _tabPadding(Widget child) => SingleChildScrollView(padding: const EdgeInsets.all(AppSpacing.lg), child: child);
}

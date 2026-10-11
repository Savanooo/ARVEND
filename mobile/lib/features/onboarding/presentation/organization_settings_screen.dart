import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/onboarding_providers.dart';
import '../domain/onboarding_state.dart';
import 'onboarding_step_forms.dart';

/// Firma Ayarları izinleri (backend /organization/settings: requireAdmin +
/// organization.settings.read okuma, .manage kaydetme). İkisi de
/// Yönetici'ye kilitli izinlerdir: `canAccess` kaba admin rolünü de ister.
const kPermOrganizationSettingsRead = 'organization.settings.read';
const kPermOrganizationSettingsManage = 'organization.settings.manage';

const _noAccessMessage =
    'Firma ayarları yalnızca Sahip ve Yönetici hesaplarına açık; rolünde "Firma ayarlarını görüntüleme" izni olmalı.';
const _readOnlyMessage =
    'Firma ayarlarını yalnızca görüntüleyebilirsin; değiştirmek için rolünde "Firma ayarlarını düzenleme" izni olmalı.';

/// Onboarding SONRASI "Firma Ayarları" düzenleme ekranı -- Diğer menüsünden
/// erişilir. AYNI 5 adım formunu (onboarding_step_forms.dart) kullanır,
/// AYNI backend state'ini okur/yazar (organizations.onboarding_step/
/// onboarding_completed + organization_profile/organization_commercial_
/// settings) ama /organization/settings/* uçları üzerinden -- sihirbazın
/// aksine, sekmeler arasında SERBEST gezinilir (zorunlu ileri/geri yok),
/// her sekme kendi "Kaydet" düğmesiyle bağımsız kaydedilir (project_detail_
/// screen.dart'taki DefaultTabController/TabBar deseniyle AYNI).
///
/// İzin: görüntüleme izni olmayan kişiye kilit ekranı; düzenleme izni
/// olmayana formlar salt-okur (Kaydet yok). Eskiden ekran yalnızca kaba
/// role bakıyordu: görüntüleme izni alınmış Yönetici hata ekranı, yalnız
/// görüntüleyebilen kişi ise Kaydet'te 403 görüyordu.
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
    // Görüntüleme izni yoksa istek atılmaz (sunucu 403 döner); izin bu
    // ekrandayken gelirse build'deki dinleyici okur.
    if (ref.read(authControllerProvider).valueOrNull.canAccess(kPermOrganizationSettingsRead)) _load();
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
    // İzin sonradan gelirse (kullanıcı yüklendi ya da yetkiler tazelendi,
    // bkz. PermissionRefreshWatcher) ayarlar o an okunur.
    ref.listen(authControllerProvider, (prev, next) {
      final could = prev?.valueOrNull.canAccess(kPermOrganizationSettingsRead) ?? false;
      if (!could && next.valueOrNull.canAccess(kPermOrganizationSettingsRead) && _state == null) _load();
    });
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canRead = user.canAccess(kPermOrganizationSettingsRead);
    final readOnly = !(canRead && user.canAccess(kPermOrganizationSettingsManage));
    final loadError = _loadError;
    final forbidden = loadError is ApiException && loadError.isForbidden;

    if (!canRead || (_state == null && forbidden)) {
      return const AppPageScaffold(
        title: Text('Firma Ayarları'),
        body: NoAccessView(message: _noAccessMessage),
      );
    }

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
            ? (loadError != null ? ErrorState(error: loadError, onRetry: _load) : const LoadingState())
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
                  if (readOnly)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
                      child: ReadOnlyNotice(_readOnlyMessage),
                    ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _tabPadding(CompanyStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.profile,
                          onSaved: _onSaved,
                          readOnly: readOnly,
                        )),
                        _tabPadding(BillingStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.profile,
                          onSaved: _onSaved,
                          readOnly: readOnly,
                        )),
                        _tabPadding(OffersStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.commercial,
                          onSaved: _onSaved,
                          readOnly: readOnly,
                        )),
                        _tabPadding(FinanceStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.commercial,
                          onSaved: _onSaved,
                          readOnly: readOnly,
                        )),
                        _tabPadding(BusinessStepForm(
                          repository: ref.read(organizationSettingsRepositoryProvider),
                          initial: state.profile,
                          onSaved: _onSaved,
                          submitLabel: 'Kaydet',
                          readOnly: readOnly,
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

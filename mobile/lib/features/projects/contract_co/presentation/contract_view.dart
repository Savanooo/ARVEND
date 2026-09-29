import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_lifecycle_actions.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../data/projects_providers.dart';
import '../../presentation/destructive_action_button.dart';
import '../contract_co_paths.dart';
import '../data/contract_co_providers.dart';
import '../domain/project_contract.dart';
import 'contract_notes_sheet.dart';
import 'widgets/change_order_list_card.dart';
import 'widgets/contract_co_ui.dart';
import 'widgets/contract_value_card.dart';

/// "Sözleşme" tam ekranı (`/projeler/:id/sozlesme`) -- gövdesi proje
/// detayının Finans > Sözleşme alt görünümüyle ([ProjectContractTab]) aynı.
class ProjectContractScreen extends StatelessWidget {
  const ProjectContractScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(title: const Text('Sözleşme'), body: ProjectContractTab(projectId: projectId));
  }
}

/// Proje Sözleşmesi (web `ContractSection.tsx`). Üç katmanlı izin
/// (docs/contracts.md §5): `contracts.read` görür, `contracts.manage`
/// taslağı oluşturur/düzenler + dahili notu yazar, `contracts.lifecycle`
/// Aktifleştir/İptal Et/Tamamla/Feshet yapar -- Proje Yöneticisi taslağı
/// hazırlar ama resmileştiremez. İzni olmayan düğmeyi GÖRMEZ; sunucu 403
/// dönerse ekran çökmez. Tamamlanmış/iptal edilmiş projede (web `locked`)
/// şartlar ve not değiştirilemez, yeni sözleşme açılmaz; yalnızca kapanış
/// eylemleri (Tamamla/Feshet/İptal Et) kalır -- backend bunlara izin verir
/// (web bunları da gizliyor; mobil backend durum makinesini izler).
///
/// Tutar YOKTUR -- yalnızca "Bu Sözleşmeyi Değiştiren Ek İşler" bölümü ve
/// sözleşme bedeli kartı, ayrıca `projects.finance.read` varsa çizilir.
class ProjectContractTab extends ConsumerWidget {
  const ProjectContractTab({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (isAuthPending(auth)) return const LoadingState();
    final user = auth.valueOrNull;
    if (!user.can(kContractsReadPermission)) {
      return const ContractCoNoAccess(message: kContractNoAccessText);
    }
    final contractAsync = ref.watch(projectContractProvider(projectId));

    Future<void> refresh() async {
      ref.invalidate(projectContractProvider(projectId));
      ref.invalidate(projectChangeOrderListProvider(projectId));
      ref.invalidate(contractValueSummaryProvider(projectId));
      try {
        await ref.read(projectContractProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    return contractAsync.when(
      loading: () => const LoadingState(),
      error: (e, _) => isForbiddenError(e)
          ? const ContractCoNoAccess(message: kContractNoAccessText)
          : ErrorState(error: e, onRetry: refresh),
      data: (contract) => RefreshIndicator(
        onRefresh: refresh,
        child: contract == null
            ? _ContractEmpty(projectId: projectId)
            : _ContractBody(projectId: projectId, contract: contract),
      ),
    );
  }
}

/// Sözleşmesiz proje (Sprint 3 öncesi projeler, backfill YOK) -- web ile
/// aynı boş durum + "Sözleşme Oluştur" (yalnızca `contracts.manage`).
class _ContractEmpty extends ConsumerStatefulWidget {
  const _ContractEmpty({required this.projectId});

  final String projectId;

  @override
  ConsumerState<_ContractEmpty> createState() => _ContractEmptyState();
}

class _ContractEmptyState extends ConsumerState<_ContractEmpty> {
  bool _busy = false;

  Future<void> _create() async {
    setState(() => _busy = true);
    // Kapsayıcı ilk await'ten ÖNCE: istek sürerken ekran kapansa da
    // sözleşme tazelenir (WidgetRef dispose sonrası StateError atardı).
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(contractCoRepositoryProvider).createContract(widget.projectId);
      invalidate(projectContractProvider(widget.projectId));
      if (mounted) showContractCoSnack(context, 'Sözleşme taslağı oluşturuldu.');
    } catch (e) {
      // 409: başka biri az önce oluşturdu -- mevcut sözleşme yüklensin.
      if (isConflictError(e)) invalidate(projectContractProvider(widget.projectId));
      if (mounted) showContractCoSnack(context, contractCoErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final project = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull;
    final locked = isProjectLocked(project);
    final canCreate = user.can(kContractsManagePermission) && !locked;

    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: (constraints.maxHeight - AppSpacing.lg * 2).clamp(0, double.infinity)),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: const Icon(Icons.handshake_outlined, color: AppColors.gold, size: 26),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    'Bu proje için henüz bir sözleşme yok',
                    style: AppTypography.sectionTitle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  // Yönlendirici metin yalnızca oluşturabilen kişiye; diğerleri
                  // yapamayacakları bir adımı tarif eden cümle görmez.
                  Text(
                    canCreate
                        ? 'Sözleşme oluşturduktan sonra kapsam ve ödeme koşullarını doldurabilirsin.'
                        : 'Bu proje için henüz sözleşme oluşturulmadı.',
                    style: AppTypography.metadata,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (canCreate)
                    PrimaryButton(
                      label: 'Sözleşme Oluştur',
                      icon: Icons.add,
                      loading: _busy,
                      onPressed: _create,
                    )
                  else if (locked)
                    const ReadOnlyNotice(kProjectLockedText)
                  else
                    const ReadOnlyNotice(kContractCreateReadOnlyText),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContractBody extends ConsumerStatefulWidget {
  const _ContractBody({required this.projectId, required this.contract});

  final String projectId;
  final ProjectContract contract;

  @override
  ConsumerState<_ContractBody> createState() => _ContractBodyState();
}

class _ContractBodyState extends ConsumerState<_ContractBody> {
  bool _busy = false;

  String get _projectId => widget.projectId;

  Future<void> _run(Future<void> Function() action, String successMessage) async {
    setState(() => _busy = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await action();
      invalidate(projectContractProvider(_projectId));
      if (mounted) showContractCoSnack(context, successMessage);
    } catch (e) {
      // 409: durum başka yerde değişti (ör. biri az önce aktifleştirdi) --
      // ekran güncel duruma dönsün, eski düğmeler kalmasın.
      if (isConflictError(e)) invalidate(projectContractProvider(_projectId));
      if (mounted) showContractCoSnack(context, contractCoErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate() async {
    final ok = await showContractCoConfirm(
      context,
      title: 'Sözleşmeyi Aktifleştir',
      message: 'Aktivasyon, ticari şartları (kapsam, ödeme/hakediş/avans koşulları, tarihler) KALICI olarak '
          'kilitler — bundan sonraki değişiklikler resmi bir Ek İş gerektirir. Bu işlem GERİ ALINAMAZ.',
      confirmLabel: 'Aktifleştir',
      danger: true,
    );
    if (!ok) return;
    await _run(() => ref.read(contractCoRepositoryProvider).activateContract(_projectId), 'Sözleşme aktifleştirildi.');
  }

  Future<void> _complete() async {
    final ok = await showContractCoConfirm(
      context,
      title: 'Sözleşmeyi Tamamla',
      message: 'Sözleşme tamamlandı olarak işaretlenecek. Bu işlem GERİ ALINAMAZ.',
      confirmLabel: 'Tamamla',
    );
    if (!ok) return;
    await _run(() => ref.read(contractCoRepositoryProvider).completeContract(_projectId), 'Sözleşme tamamlandı.');
  }

  Future<void> _cancel() async {
    final reason = await showReasonDialog(
      context,
      title: 'Sözleşmeyi İptal Et',
      message: 'Bu taslak sözleşme iptal edilecek. Bu işlem GERİ ALINAMAZ.',
      confirmLabel: 'İptal Et',
      reasonLabel: 'İptal nedeni',
    );
    if (reason == null || reason.isEmpty) return;
    await _run(
      () => ref.read(contractCoRepositoryProvider).cancelContract(_projectId, reason: reason),
      'Sözleşme iptal edildi.',
    );
  }

  Future<void> _terminate() async {
    final reason = await showReasonDialog(
      context,
      title: 'Sözleşmeyi Feshet',
      message: 'Aktif sözleşme erken feshedilecek. Bu işlem GERİ ALINAMAZ.',
      confirmLabel: 'Feshet',
      reasonLabel: 'Fesih nedeni',
    );
    if (reason == null || reason.isEmpty) return;
    await _run(
      () => ref.read(contractCoRepositoryProvider).terminateContract(_projectId, reason: reason),
      'Sözleşme feshedildi.',
    );
  }

  Future<void> _editNotes() async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final updated = await showContractNotesSheet(context, projectId: _projectId, initial: widget.contract.internalNotes);
    if (updated == null) return;
    invalidate(projectContractProvider(_projectId));
    if (mounted) showContractCoSnack(context, 'Not kaydedildi.');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.contract;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final project = ref.watch(projectDetailProvider(_projectId)).valueOrNull;
    final locked = isProjectLocked(project);
    final canManage = user.can(kContractsManagePermission) && !locked;
    // Yaşam döngüsü proje kilidine BİLİNÇLİ OLARAK bağlı değil (backend
    // project_contract_service.go): kapalı projede sözleşmeyi Tamamla/
    // Feshet/İptal Et anlamlı bir KAPANIŞ eylemidir. Yalnızca Aktifleştir
    // (ticari şartları başlatmak) açık proje ister.
    final hasLifecycle = user.can(kContractsLifecyclePermission);
    final canActivate = hasLifecycle && !locked && c.canActivate;
    final canClose = hasLifecycle && (c.canComplete || c.canCancel || c.canTerminate);
    final canSeeMoney = user.can(kChangeOrdersReadPermission);

    final actions = <AppLifecycleAction>[
      if (canActivate)
        AppLifecycleAction(
          label: 'Aktifleştir',
          icon: Icons.verified_outlined,
          primary: true,
          loading: _busy,
          onPressed: _busy ? null : _activate,
        ),
      if (hasLifecycle && c.canComplete)
        AppLifecycleAction(
          label: 'Tamamla',
          icon: Icons.task_alt,
          primary: true,
          loading: _busy,
          onPressed: _busy ? null : _complete,
        ),
    ];
    // Geri alınamaz iptal/fesih aksiyon çubuğundan ayrı, kırmızı (bkz.
    // DestructiveActionButton).
    final destructive = <Widget>[
      if (hasLifecycle && c.canCancel)
        DestructiveActionButton(label: 'İptal Et', loading: _busy, onPressed: _busy ? null : _cancel),
      if (hasLifecycle && c.canTerminate)
        DestructiveActionButton(
          label: 'Feshet',
          icon: Icons.gavel_outlined,
          loading: _busy,
          onPressed: _busy ? null : _terminate,
        ),
    ];

    // Hangi bilgilendirme kutusu: proje kapalı > hiç yazma izni yok >
    // taslağı düzenleyebilir ama durumu değiştiremez (Proje Yöneticisi).
    final String? notice = locked
        ? (canClose ? kContractLockedClosingText : kProjectLockedText)
        : (!user.can(kContractsManagePermission) && !user.can(kContractsLifecyclePermission))
            ? kContractReadOnlyText
            : (!user.can(kContractsLifecyclePermission) && !c.isTerminal)
                ? kContractNoLifecycleText
                : null;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Proje Sözleşmesi', style: AppTypography.cardTitle)),
                  StatusRegistry.build(c.status, kContractStatusRegistry),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(c.statusExplanation, style: AppTypography.metadata.copyWith(height: 1.35)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                AppLifecycleActions(actions: actions),
              ],
              for (final d in destructive) ...[
                SizedBox(height: actions.isEmpty ? AppSpacing.lg : AppSpacing.sm),
                d,
              ],
            ],
          ),
        ),
        if (notice != null) ...[const SizedBox(height: AppSpacing.md), ReadOnlyNotice(notice)],
        const SizedBox(height: AppSpacing.md),
        ContractCoCard(
          title: 'Sözleşme Şartları',
          trailing: (canManage && c.termsEditable)
              ? IconButton(
                  tooltip: 'Şartları Düzenle',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: _busy ? null : () => context.push(projectContractEditPath(_projectId)),
                )
              : null,
          children: [
            if (!c.termsEditable) ...[
              Text(
                'Aktivasyon sonrası ticari şartlar kilitlidir — değişiklik için resmi bir Ek İş gereklidir.',
                style: AppTypography.helper.copyWith(height: 1.35),
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            ContractCoInfoRow(label: 'Yürürlük Tarihi', value: c.effectiveDate == null ? null : Formatters.date(c.effectiveDate)),
            ContractCoInfoRow(
              label: 'Planlanan Bitiş',
              value: c.plannedCompletionDate == null ? null : Formatters.date(c.plannedCompletionDate),
            ),
            ContractCoInfoRow(label: 'Kapsam', value: c.scope),
            ContractCoInfoRow(label: 'Ödeme Koşulları', value: c.paymentTerms),
            ContractCoInfoRow(label: 'Hakediş Koşulları', value: c.retentionTerms),
            ContractCoInfoRow(label: 'Avans Koşulları', value: c.advanceTerms),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        ContractCoCard(
          title: 'Dahili Not (yalnızca ekip görür)',
          trailing: (canManage && c.notesEditable)
              ? IconButton(
                  tooltip: 'Notu Düzenle',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_note_outlined, size: 22),
                  onPressed: _busy ? null : _editNotes,
                )
              : null,
          children: [
            Text(
              c.internalNotes.isEmpty ? '—' : c.internalNotes,
              style: AppTypography.body.copyWith(
                color: c.internalNotes.isEmpty ? AppColors.textMuted : null,
                height: 1.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _HistoryCard(contract: c),
        if (canSeeMoney) _ContractChangeOrders(projectId: _projectId),
      ],
    );
  }
}

/// Durum geçmişi -- yalnızca gerçekleşmiş adımlar (zaman damgası dolu).
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.contract});

  final ProjectContract contract;

  @override
  Widget build(BuildContext context) {
    final c = contract;
    final rows = <Widget>[
      if (c.createdAt.isNotEmpty) ContractCoInfoRow(label: 'Oluşturuldu', value: formatDateTimeTr(c.createdAt)),
      if (c.activatedAt != null) ContractCoInfoRow(label: 'Aktifleştirildi', value: formatDateTimeTr(c.activatedAt)),
      if (c.completedAt != null) ContractCoInfoRow(label: 'Tamamlandı', value: formatDateTimeTr(c.completedAt)),
      if (c.cancelledAt != null) ...[
        ContractCoInfoRow(label: 'İptal Edildi', value: formatDateTimeTr(c.cancelledAt), valueColor: AppColors.danger),
        ContractCoInfoRow(label: 'İptal Nedeni', value: c.cancelReason),
      ],
      if (c.terminatedAt != null) ...[
        ContractCoInfoRow(label: 'Feshedildi', value: formatDateTimeTr(c.terminatedAt), valueColor: AppColors.danger),
        ContractCoInfoRow(label: 'Fesih Nedeni', value: c.terminationReason),
      ],
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return ContractCoCard(title: 'Durum Geçmişi', children: rows);
  }
}

/// "Bu Sözleşmeyi Değiştiren Ek İşler" + sözleşme bedeli kırılımı. Liste
/// ucu `projects.finance.read` ister -- 403 olursa bölüm sessizce gizlenir.
class _ContractChangeOrders extends ConsumerWidget {
  const _ContractChangeOrders({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(projectChangeOrderListProvider(projectId));
    final summary = ref.watch(contractValueSummaryProvider(projectId)).valueOrNull;
    if (listAsync.hasError && isForbiddenError(listAsync.error)) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary != null) ...[const SizedBox(height: AppSpacing.md), ContractValueCard(summary: summary)],
        const SizedBox(height: AppSpacing.xl),
        AppSectionHeader(
          title: 'Bu Sözleşmeyi Değiştiren Ek İşler',
          trailing: TextButton(
            onPressed: () => context.push(projectChangeOrdersPath(projectId)),
            child: const Text('Tümü'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AsyncStateView(
          value: listAsync,
          onRetry: () async => ref.invalidate(projectChangeOrderListProvider(projectId)),
          isEmpty: (list) => list.isEmpty,
          emptyBuilder: (_) => const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text('Henüz ek iş/değişiklik emri yok.', style: AppTypography.metadata),
          ),
          data: (context, list) => Column(
            children: [
              for (final co in list)
                ChangeOrderListCard(
                  changeOrder: co,
                  onTap: () => context.push(projectChangeOrderPath(projectId, co.id)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

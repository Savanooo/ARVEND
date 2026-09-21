import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_status_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_financial_summary.dart';
import '../../../core/widgets/app_lifecycle_actions.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';

/// Sprint 5 P2 — Hakediş (Progress Claim) detayı. `net_payable` bir
/// YÜKÜMLÜLÜKTÜR (henüz ödenmedi) -- gerçek nakit çıkışı
/// `SubcontractPayment`'tadır, burada KARIŞTIRILMAZ (bkz. domain yorumu).
/// P3: Brüt/Kesintiler/Net Hakediş bir grupta, "Ödeme Durumu" (sertifika
/// edilen vs. gerçekten ödenen) AYRI bir bölümde gösterilir -- ikisi
/// GÖRSEL OLARAK BİRLEŞTİRİLMEZ (bkz. ürün brief'i). Ödenen tutar,
/// zaten mevcut `subcontractPaymentsProvider`den (taşeronun TÜM ödemeleri)
/// bu hakedişin `id`sine göre İSTEMCİ TARAFINDA süzülür -- yeni bir uç
/// nokta İCAT EDİLMEZ.
class ProgressClaimDetailScreen extends ConsumerWidget {
  const ProgressClaimDetailScreen({
    super.key,
    required this.projectId,
    required this.subcontractId,
    required this.claimId,
  });

  final String projectId;
  final String subcontractId;
  final String claimId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, claimId: claimId);
    final detailAsync = ref.watch(progressClaimDetailProvider(args));

    return AppPageScaffold(
      title: detailAsync.maybeWhen(
        data: (d) => Text(d.claim.claimNumber),
        orElse: () => const Text('Hakediş'),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(progressClaimDetailProvider(args)),
        data: (context, detail) => _ProgressClaimDetailBody(
          projectId: projectId,
          subcontractId: subcontractId,
          claimId: claimId,
          claim: detail.claim,
          items: detail.items,
        ),
      ),
    );
  }
}

class _ProgressClaimDetailBody extends ConsumerWidget {
  const _ProgressClaimDetailBody({
    required this.projectId,
    required this.subcontractId,
    required this.claimId,
    required this.claim,
    required this.items,
  });

  final String projectId;
  final String subcontractId;
  final String claimId;
  final ProgressClaim claim;
  final List<ProgressClaimItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontract_claims.manage');
    final canCertify =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontract_claims.certify');
    // Backend'in tek para birimi kaynağı sözleşmedir (progressClaimResponse
    // currency taşımaz) -- taşeron sözleşmesinin ÖNCEDEN yüklenmiş
    // detayından okunur, yeni bir istek atılmaz.
    final scArgs = (projectId: projectId, subcontractId: subcontractId);
    final currency = ref.watch(subcontractDetailProvider(scArgs)).valueOrNull?.subcontract.currency ?? 'TRY';
    final paymentsAsync = ref.watch(subcontractPaymentsProvider(scArgs));
    final matchingPayments =
        paymentsAsync.valueOrNull?.where((p) => p.progressClaimId == claim.id && !p.isVoided).toList();
    final paidAgainstClaim = matchingPayments?.fold<double>(0, (sum, p) => sum + p.amount);
    final remainingUnpaid = paidAgainstClaim == null ? null : claim.currentCertifiedAmount - paidAgainstClaim;

    void refreshAll() {
      final claimArgs = (projectId: projectId, claimId: claimId);
      ref.invalidate(progressClaimDetailProvider(claimArgs));
      ref.invalidate(subcontractProgressClaimsProvider(scArgs));
      // Sertifikasyon certified_to_date/remaining_commitment/remaining_payable'ı
      // etkiler (bkz. backend GetSubcontractCertifiedToDate) -- sözleşme
      // detayı da tazelenmeli.
      ref.invalidate(subcontractDetailProvider(scArgs));
      ref.invalidate(subcontractPaymentsProvider(scArgs));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          StatusRegistry.build(claim.status, StatusRegistry.progressClaim),
          const SizedBox(height: AppSpacing.md),
          _ProgressClaimLifecycleActionsBar(
            projectId: projectId,
            subcontractId: subcontractId,
            claimId: claimId,
            claim: claim,
            canManage: canManage,
            canCertify: canCertify,
            onChanged: refreshAll,
          ),
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Hakediş'),
          const SizedBox(height: AppSpacing.sm),
          AppFinancialSummary(
            rows: [
              AppDataRow(
                label: 'Dönem Sonu',
                value: claim.periodEnd.isNotEmpty ? Formatters.date(claim.periodEnd) : '-',
              ),
              if (claim.periodStart != null)
                AppDataRow(label: 'Dönem Başı', value: Formatters.date(claim.periodStart!)),
              const Divider(height: AppSpacing.xl),
              AppDataRow(
                label: 'Brüt Hakediş Tutarı',
                value: Formatters.money(claim.grossWorkAmount, currency: currency),
              ),
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
                child: Text('Kesintiler', style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700)),
              ),
              AppDataRow(
                label: 'Teminat Kesintisi (%${claim.retentionPercentSnapshot.toStringAsFixed(2)})',
                value: '-${Formatters.money(claim.retentionAmount, currency: currency)}',
                valueColor: AppStatusColors.error,
              ),
              if (claim.advanceRecoveryAmount != 0)
                AppDataRow(
                  label: 'Avans Mahsubu',
                  value: '-${Formatters.money(claim.advanceRecoveryAmount, currency: currency)}',
                  valueColor: AppStatusColors.error,
                ),
              if (claim.otherDeductions != 0)
                AppDataRow(
                  label: 'Diğer Kesintiler',
                  value: '-${Formatters.money(claim.otherDeductions, currency: currency)}',
                  valueColor: AppStatusColors.error,
                ),
              const Divider(height: AppSpacing.xl),
              AppDataRow(
                label: 'Net Hakediş',
                value: Formatters.money(claim.netPayable, currency: currency),
                emphasize: true,
              ),
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Bu bir yükümlülüktür, henüz ödendiği anlamına gelmez -- ayrıntılar aşağıdaki '
                  'Ödeme Durumu bölümündedir.',
                  style: AppTypography.helper,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Ödeme Durumu'),
          const SizedBox(height: AppSpacing.sm),
          AppFinancialSummary(
            rows: [
              AppDataRow(
                label: 'Önceki Kümülatif Sertifika',
                value: Formatters.money(claim.previousCertifiedAmount, currency: currency),
              ),
              AppDataRow(
                label: 'Güncel Kümülatif Sertifika',
                value: Formatters.money(claim.currentCertifiedAmount, currency: currency),
              ),
              if (paidAgainstClaim != null) ...[
                const Divider(height: AppSpacing.xl),
                AppDataRow(
                  label: 'Bu Hakedişe Karşı Ödenen',
                  value: Formatters.money(paidAgainstClaim, currency: currency),
                  valueColor: AppStatusColors.success,
                ),
                AppDataRow(
                  label: 'Ödenmemiş Kalan',
                  value: Formatters.money(remainingUnpaid!, currency: currency),
                  emphasize: true,
                  valueColor: remainingUnpaid > 0.0009 ? AppStatusColors.warning : AppStatusColors.success,
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Sertifika edilmiş olmak ödendiği anlamına gelmez -- gerçek ödeme kayıtları taşeron '
                  'sözleşmesindeki "Ödemeler" bölümünde tutulur.',
                  style: AppTypography.helper,
                ),
              ),
            ],
          ),
          if (claim.status == ProgressClaim.statusRejected && claim.rejectionReason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              color: AppColors.danger.withValues(alpha: 0.06),
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Red Gerekçesi', style: AppTypography.cardTitle.copyWith(color: AppColors.danger)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(claim.rejectionReason, style: AppTypography.body),
                ],
              ),
            ),
          ],
          if (claim.notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Notlar', style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(claim.notes, style: AppTypography.body),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'SOV Kalemleri'),
          const SizedBox(height: AppSpacing.sm),
          if (items.isEmpty)
            const EmptyStateView(message: 'Kalem yok.', icon: Icons.list_alt_outlined)
          else
            ...items.map((it) => AppCard(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(it.itemDescription, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                      const SizedBox(height: AppSpacing.xs),
                      AppDataRow(label: 'Sözleşme Bedeli (kalem)', value: Formatters.money(it.scheduledValue, currency: currency)),
                      AppDataRow(label: 'Bu Hakedişte', value: Formatters.money(it.currentProgressAmount, currency: currency)),
                      AppDataRow(label: 'Kümülatif', value: Formatters.money(it.cumulativeProgressAmount, currency: currency)),
                      AppDataRow(label: 'İlerleme', value: '%${it.progressPercent.toStringAsFixed(1)}'),
                      AppDataRow(label: 'Kalan', value: Formatters.money(it.remainingAmount, currency: currency)),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}

/// Düzenle/Gönder/Sertifikala/Reddet/İptal -- yalnızca UX kolaylığı, backend
/// HER geçişi bağımsız olarak reddeder. Certify/Reject
/// `subcontract_claims.certify` gerektirir (Manage İLE AYNI DEĞİL) --
/// bkz. Phase 1 bulgusu: reject bile certify izni ister, manage değil.
class _ProgressClaimLifecycleActionsBar extends ConsumerStatefulWidget {
  const _ProgressClaimLifecycleActionsBar({
    required this.projectId,
    required this.subcontractId,
    required this.claimId,
    required this.claim,
    required this.canManage,
    required this.canCertify,
    required this.onChanged,
  });

  final String projectId;
  final String subcontractId;
  final String claimId;
  final ProgressClaim claim;
  final bool canManage;
  final bool canCertify;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ProgressClaimLifecycleActionsBar> createState() => _ProgressClaimLifecycleActionsBarState();
}

class _ProgressClaimLifecycleActionsBarState extends ConsumerState<_ProgressClaimLifecycleActionsBar> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Onayla')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _promptReason(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Gerekçe'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Onayla'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(projectsRepositoryProvider);
    final claim = widget.claim;
    final actions = <AppLifecycleAction>[];

    if (claim.isEditable && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'Düzenle',
        icon: Icons.edit_outlined,
        onPressed: _busy
            ? null
            : () => context.push(
                '/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/hakedisler/${widget.claimId}/duzenle'),
      ));
    }
    if (claim.canSubmit && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'Gönder',
        icon: Icons.send_outlined,
        primary: true,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Gönder', 'Bu hakediş sertifikasyon için gönderilsin mi?');
                if (!ok) return;
                await _run(() => repo.submitProgressClaim(widget.projectId, widget.claimId));
              },
      ));
    }
    if (claim.canCancel && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'İptal Et',
        icon: Icons.cancel_outlined,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('İptal Et', 'Bu hakediş iptal edilsin mi?');
                if (!ok) return;
                await _run(() => repo.cancelProgressClaim(widget.projectId, widget.claimId));
              },
      ));
    }
    if (claim.canCertify && widget.canCertify) {
      actions.add(AppLifecycleAction(
        label: 'Sertifikala',
        icon: Icons.verified_outlined,
        primary: true,
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm(
                    'Sertifikala', 'Bu hakediş sertifikalansın mı? Sertifikalandıktan sonra bu kayıt kilitlenir.');
                if (!ok) return;
                await _run(() => repo.certifyProgressClaim(widget.projectId, widget.claimId));
              },
      ));
    }
    if (claim.canReject && widget.canCertify) {
      actions.add(AppLifecycleAction(
        label: 'Reddet',
        icon: Icons.thumb_down_outlined,
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Hakedişi Reddet');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.rejectProgressClaim(widget.projectId, widget.claimId, reason: reason));
              },
      ));
    }

    return AppLifecycleActions(actions: actions);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';

/// Sprint 5 P2 — Hakediş (Progress Claim) detayı. `net_payable` bir
/// YÜKÜMLÜLÜKTÜR (henüz ödenmedi) -- gerçek nakit çıkışı
/// `SubcontractPayment`'tadır, burada KARIŞTIRILMAZ (bkz. domain yorumu).
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

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.claim.claimNumber),
          orElse: () => const Text('Hakediş'),
        ),
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

    void refreshAll() {
      final claimArgs = (projectId: projectId, claimId: claimId);
      ref.invalidate(progressClaimDetailProvider(claimArgs));
      ref.invalidate(subcontractProgressClaimsProvider(scArgs));
      // Sertifikasyon certified_to_date/remaining_commitment/remaining_payable'ı
      // etkiler (bkz. backend GetSubcontractCertifiedToDate) -- sözleşme
      // detayı da tazelenmeli.
      ref.invalidate(subcontractDetailProvider(scArgs));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(claim.status, StatusRegistry.progressClaim),
              Text(Formatters.money(claim.netPayable, currency: currency),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ],
          ),
          const SizedBox(height: 12),
          _ProgressClaimLifecycleActionsBar(
            projectId: projectId,
            subcontractId: subcontractId,
            claimId: claimId,
            claim: claim,
            canManage: canManage,
            canCertify: canCertify,
            onChanged: refreshAll,
          ),
          const SizedBox(height: 4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Row('Dönem Sonu', claim.periodEnd.isNotEmpty ? Formatters.date(claim.periodEnd) : '-'),
                  if (claim.periodStart != null) _Row('Dönem Başı', Formatters.date(claim.periodStart!)),
                  const Divider(height: 20),
                  _Row('Brüt Hakediş', Formatters.money(claim.grossWorkAmount, currency: currency)),
                  _Row('Kesinti (Retention %${claim.retentionPercentSnapshot.toStringAsFixed(2)})',
                      '-${Formatters.money(claim.retentionAmount, currency: currency)}'),
                  if (claim.advanceRecoveryAmount != 0)
                    _Row('Avans Mahsubu', '-${Formatters.money(claim.advanceRecoveryAmount, currency: currency)}'),
                  if (claim.otherDeductions != 0)
                    _Row('Diğer Kesintiler', '-${Formatters.money(claim.otherDeductions, currency: currency)}'),
                  const Divider(height: 20),
                  _Row('Net Ödenecek (Yükümlülük)', Formatters.money(claim.netPayable, currency: currency)),
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'Bu bir yükümlülüktür, gerçek ödeme DEĞİLDİR -- gerçek ödeme kaydı sözleşme detayındaki '
                      '"Ödemeler" bölümünde tutulur.',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                  ),
                  const Divider(height: 20),
                  _Row('Önceki Kümülatif Sertifika', Formatters.money(claim.previousCertifiedAmount, currency: currency)),
                  _Row('Güncel Kümülatif Sertifika', Formatters.money(claim.currentCertifiedAmount, currency: currency)),
                ],
              ),
            ),
          ),
          if (claim.status == ProgressClaim.statusRejected && claim.rejectionReason.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.danger.withValues(alpha: 0.06),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Red Gerekçesi', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
                    const SizedBox(height: 4),
                    Text(claim.rejectionReason),
                  ],
                ),
              ),
            ),
          ],
          if (claim.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Notlar', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(claim.notes),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text('SOV Kalemleri', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Kalem yok.', style: TextStyle(color: Colors.grey)),
            )
          else
            ...items.map((it) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.itemDescription, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        _Row('Sözleşme Bedeli (kalem)', Formatters.money(it.scheduledValue, currency: currency)),
                        _Row('Bu Hakedişte', Formatters.money(it.currentProgressAmount, currency: currency)),
                        _Row('Kümülatif', Formatters.money(it.cumulativeProgressAmount, currency: currency)),
                        _Row('İlerleme', '%${it.progressPercent.toStringAsFixed(1)}'),
                        _Row('Kalan', Formatters.money(it.remainingAmount, currency: currency)),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.grey))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
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
    final buttons = <Widget>[];

    if (claim.isEditable && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Düzenle'),
        onPressed: _busy
            ? null
            : () => context.push(
                '/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/hakedisler/${widget.claimId}/duzenle'),
      ));
    }
    if (claim.canSubmit && widget.canManage) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.send_outlined, size: 18),
        label: const Text('Gönder'),
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
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.cancel_outlined, size: 18, color: AppColors.danger),
        label: const Text('İptal Et', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
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
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.verified_outlined, size: 18),
        label: const Text('Sertifikala'),
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
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.thumb_down_outlined, size: 18, color: AppColors.danger),
        label: const Text('Reddet', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Hakedişi Reddet');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.rejectProgressClaim(widget.projectId, widget.claimId, reason: reason));
              },
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

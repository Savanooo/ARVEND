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
import 'subcontract_payment_form_sheet.dart';

/// Sprint 5 — Taşeron Sözleşmesi detayı. SOV/hakediş mobilde YALNIZCA OKUMA
/// (değişiklik emri onayı gibi hassas karar anları web'de kalır); ödeme
/// kaydı (GERÇEK nakit çıkışı) TEK yazma aksiyonudur -- backend Sprint 5
/// follow-up'ın (migration 0039) mobildeki karşılığı.
///
/// current_value/certified_to_date/remaining_commitment (taahhüt ekseni) ile
/// paid_to_date/remaining_payable (nakit ekseni) BİLİNÇLİ OLARAK AYRI
/// gösterilir -- sertifikasyon ödeme DEĞİLDİR, ikisi TEK bir rakamda
/// BİRLEŞTİRİLMEZ (bkz. backend SubcontractValueSummary yorumu).
class SubcontractDetailScreen extends ConsumerWidget {
  const SubcontractDetailScreen({super.key, required this.projectId, required this.subcontractId});
  final String projectId;
  final String subcontractId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, subcontractId: subcontractId);
    final detailAsync = ref.watch(subcontractDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.subcontract.subcontractNo),
          orElse: () => const Text('Taşeron Sözleşmesi'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(subcontractDetailProvider(args)),
        data: (context, detail) => _SubcontractDetailBody(projectId: projectId, subcontractId: subcontractId, detail: detail),
      ),
    );
  }
}

class _SubcontractDetailBody extends ConsumerWidget {
  const _SubcontractDetailBody({required this.projectId, required this.subcontractId, required this.detail});
  final String projectId;
  final String subcontractId;
  final ({Subcontract subcontract, List<SubcontractItem> items, SubcontractValue value}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, subcontractId: subcontractId);
    final paymentsAsync = ref.watch(subcontractPaymentsProvider(args));
    final claimsAsync = ref.watch(subcontractProgressClaimsProvider(args));
    final sc = detail.subcontract;
    final value = detail.value;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.approve');

    void refreshAll() {
      ref.invalidate(subcontractDetailProvider(args));
      ref.invalidate(subcontractPaymentsProvider(args));
      // Yeni-modül taşeron ödemeleri financial-summary/cost-control'e
      // AKAR (migration 0039 follow-up) -- proje özetinin bayatlamaması
      // için bunlar da tazelenir (Tahsilat akışıyla AYNI ilke). Yaşam
      // döngüsü aksiyonları (activate/complete/cancel/terminate) commitment
      // senkronizasyonu yaptığından + liste sekmesindeki durum rozetinin
      // bayatlamaması için subcontracts listesi de tazelenir.
      ref.invalidate(projectFinancialSummaryProvider(projectId));
      ref.invalidate(projectCostControlProvider(projectId));
      ref.invalidate(projectSubcontractsProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async {
        refreshAll();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(sc.status, StatusRegistry.subcontract),
              Text(Formatters.money(value.currentValue, currency: sc.currency),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ],
          ),
          const SizedBox(height: 12),
          _LifecycleActionsBar(
            projectId: projectId,
            subcontractId: subcontractId,
            subcontract: sc,
            canManage: canManage,
            canApprove: canApprove,
            onChanged: refreshAll,
          ),
          const SizedBox(height: 4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sc.supplierName ?? sc.supplierCode ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (sc.title.isNotEmpty) Text(sc.title, style: const TextStyle(color: Colors.grey)),
                  const Divider(height: 20),
                  _Row('Sözleşme Bedeli', Formatters.money(sc.originalAmount, currency: sc.currency)),
                  _Row('Güncel Değer', Formatters.money(value.currentValue, currency: sc.currency)),
                  if (sc.retentionPercent != null)
                    _Row('Hakediş Kesintisi (Retention)', '%${sc.retentionPercent!.toStringAsFixed(2)}'),
                  if (sc.advanceAmount != null)
                    _Row('Avans Tutarı', Formatters.money(sc.advanceAmount!, currency: sc.currency)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Taahhüt ekseni (SOV bazlı, hakediş sertifikasyonuyla değişir).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Taahhüt', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  _Row('Sertifika Edilen (Hakediş)', Formatters.money(value.certifiedToDate, currency: sc.currency)),
                  _Row('Kalan Taahhüt', Formatters.money(value.remainingCommitment, currency: sc.currency)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Nakit ekseni (GERÇEK ödeme, sertifikasyondan BAĞIMSIZ).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Ödeme', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  _Row('Ödenen', Formatters.money(value.paidToDate, currency: sc.currency)),
                  _Row(
                    'Ödenecek Kalan (Sertifika − Ödenen)',
                    Formatters.money(value.remainingPayable, currency: sc.currency),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('SOV / İş Kalemleri', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (detail.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Kalem yok.', style: TextStyle(color: Colors.grey)),
            )
          else
            ...detail.items.map((item) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: item.unit.isNotEmpty && item.quantity != null
                        ? Text('${item.quantity} ${item.unit}')
                        : null,
                    trailing: Text(Formatters.money(item.originalAmount, currency: sc.currency),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                )),
          const SizedBox(height: 16),
          const Text('Hakedişler', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          AsyncStateView(
            value: claimsAsync,
            onRetry: () async => ref.invalidate(subcontractProgressClaimsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Henüz hakediş yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, claims) => Column(
              children: claims
                  .map((c) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          title: Text(c.claimNumber),
                          subtitle: StatusRegistry.build(c.status, StatusRegistry.progressClaim),
                          trailing: Text(Formatters.money(c.netPayable, currency: sc.currency),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Ödemeler', style: TextStyle(fontWeight: FontWeight.w700)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ödeme Ekle'),
                onPressed: () async {
                  final created = await showSubcontractPaymentFormSheet(
                    context,
                    projectId,
                    subcontractId,
                    currency: sc.currency,
                  );
                  if (created != null) refreshAll();
                },
              ),
            ],
          ),
          AsyncStateView(
            value: paymentsAsync,
            onRetry: () async => ref.invalidate(subcontractPaymentsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Henüz ödeme kaydı yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, payments) => Column(
              children: payments
                  .map((p) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          title: Text(p.paymentMethod.isEmpty ? 'Ödeme' : p.paymentMethod),
                          subtitle: Text(
                            [
                              Formatters.date(p.paidDate),
                              if (p.description.isNotEmpty) p.description,
                              if (p.referenceNo.isNotEmpty) p.referenceNo,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            Formatters.money(p.amount, currency: sc.currency),
                            style: TextStyle(
                              decoration: p.isVoided ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aktivasyon/tamamlama/iptal/fesih -- yalnızca UX kolaylığı (görünürlük
/// durum+izne göre süzülür), backend HER durumda bağımsız olarak reddeder
/// (bkz. `ProjectService.ActivateSubcontract` vb. -- her biri kendi
/// durum-korumalı SQL'iyle çalışır). "Düzenle" YALNIZCA `draft`ta ve
/// `subcontracts.manage` iznine sahipken görünür; diğer dördü
/// `subcontracts.approve` gerektirir (legacy_user/project_manager bu izne
/// SAHİP DEĞİL -- bkz. backend migration 0038 rol matrisi).
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.subcontractId,
    required this.subcontract,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String subcontractId;
  final Subcontract subcontract;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_LifecycleActionsBar> createState() => _LifecycleActionsBarState();
}

class _LifecycleActionsBarState extends ConsumerState<_LifecycleActionsBar> {
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
    final sc = widget.subcontract;
    final buttons = <Widget>[];

    if (sc.isEditable && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Düzenle'),
        onPressed: _busy
            ? null
            : () => context.push('/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/duzenle'),
      ));
    }
    if (sc.canActivate && widget.canApprove) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.play_arrow, size: 18),
        label: const Text('Aktifleştir'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm(
                    'Aktifleştir', 'Bu taşeron sözleşmesi aktifleştirilsin mi? Ticari şartlar bundan sonra kilitlenir.');
                if (!ok) return;
                await _run(() => repo.activateSubcontract(widget.projectId, widget.subcontractId));
              },
      ));
    }
    if (sc.canCancel && widget.canApprove) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.cancel_outlined, size: 18, color: AppColors.danger),
        label: const Text('İptal Et', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Sözleşmeyi İptal Et');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.cancelSubcontract(widget.projectId, widget.subcontractId, reason: reason));
              },
      ));
    }
    if (sc.canComplete && widget.canApprove) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: const Text('Tamamla'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Tamamla', 'Bu taşeron sözleşmesi tamamlandı olarak işaretlensin mi?');
                if (!ok) return;
                await _run(() => repo.completeSubcontract(widget.projectId, widget.subcontractId));
              },
      ));
    }
    if (sc.canTerminate && widget.canApprove) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.block, size: 18, color: AppColors.danger),
        label: const Text('Feshet', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Sözleşmeyi Feshet');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.terminateSubcontract(widget.projectId, widget.subcontractId, reason: reason));
              },
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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

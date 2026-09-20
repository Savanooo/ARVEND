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

/// Sprint 5 P2 — Taşeron Değişiklik Emri detayı (`subcontract_change_orders`,
/// MALİYET tarafı) -- Sprint-3'ün "Ek İşler" (GELİR tarafı) İLE
/// KARIŞTIRILMAMALI, bkz. domain/subcontract.dart dosya başı notu.
class SubcontractChangeOrderDetailScreen extends ConsumerWidget {
  const SubcontractChangeOrderDetailScreen({
    super.key,
    required this.projectId,
    required this.subcontractId,
    required this.changeOrderId,
  });

  final String projectId;
  final String subcontractId;
  final String changeOrderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, changeOrderId: changeOrderId);
    final detailAsync = ref.watch(subcontractChangeOrderDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.changeOrder.number),
          orElse: () => const Text('Değişiklik Emri'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(subcontractChangeOrderDetailProvider(args)),
        data: (context, detail) => _ChangeOrderDetailBody(
          projectId: projectId,
          subcontractId: subcontractId,
          changeOrderId: changeOrderId,
          changeOrder: detail.changeOrder,
          items: detail.items,
        ),
      ),
    );
  }
}

class _ChangeOrderDetailBody extends ConsumerWidget {
  const _ChangeOrderDetailBody({
    required this.projectId,
    required this.subcontractId,
    required this.changeOrderId,
    required this.changeOrder,
    required this.items,
  });

  final String projectId;
  final String subcontractId;
  final String changeOrderId;
  final SubcontractChangeOrder changeOrder;
  final List<SubcontractChangeOrderItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.subcontracts.approve');
    final scArgs = (projectId: projectId, subcontractId: subcontractId);
    final currency = ref.watch(subcontractDetailProvider(scArgs)).valueOrNull?.subcontract.currency ?? 'TRY';

    void refreshAll() {
      final coArgs = (projectId: projectId, changeOrderId: changeOrderId);
      ref.invalidate(subcontractChangeOrderDetailProvider(coArgs));
      ref.invalidate(subcontractChangeOrdersProvider(scArgs));
      // Onay, ana sözleşmenin current_value/commitment'ını değiştirir (bkz.
      // syncSubcontractCommitments) -- sözleşme detayı da tazelenmeli.
      ref.invalidate(subcontractDetailProvider(scArgs));
      ref.invalidate(projectCostControlProvider(projectId));
    }

    final signed = changeOrder.signedAmount;
    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(changeOrder.status, StatusRegistry.subcontractChangeOrder),
              Text(
                '${signed >= 0 ? '+' : ''}${Formatters.money(signed, currency: currency)}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: changeOrder.changeType == SubcontractChangeOrder.typeAddition ? Colors.green : Colors.red,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ChangeOrderLifecycleActionsBar(
            projectId: projectId,
            subcontractId: subcontractId,
            changeOrderId: changeOrderId,
            changeOrder: changeOrder,
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
                  Text(changeOrder.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (changeOrder.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(changeOrder.description, style: const TextStyle(color: Colors.grey)),
                  ],
                  const Divider(height: 20),
                  _Row('Tür', changeOrder.changeType == SubcontractChangeOrder.typeAddition ? 'Ek İş (+)' : 'Kesinti (-)'),
                  _Row('Toplam Tutar', Formatters.money(changeOrder.amount, currency: currency)),
                  if (changeOrder.reason.isNotEmpty) _Row('Gerekçe', changeOrder.reason),
                ],
              ),
            ),
          ),
          if (changeOrder.status == SubcontractChangeOrder.statusRejected && changeOrder.rejectionReason.isNotEmpty) ...[
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
                    Text(changeOrder.rejectionReason),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Kalem yok.', style: TextStyle(color: Colors.grey)),
            )
          else
            ...items.map((it) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Text(it.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text(Formatters.money(it.amount, currency: currency),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
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

/// Düzenle/Gönder/İptal `subcontracts.manage` -- Onayla/Reddet
/// `subcontracts.approve` (bkz. Phase 1: değişiklik emirlerinin KENDİ izni
/// YOK, ana sözleşmenin manage/approve'unu PAYLAŞIR).
class _ChangeOrderLifecycleActionsBar extends ConsumerStatefulWidget {
  const _ChangeOrderLifecycleActionsBar({
    required this.projectId,
    required this.subcontractId,
    required this.changeOrderId,
    required this.changeOrder,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String subcontractId;
  final String changeOrderId;
  final SubcontractChangeOrder changeOrder;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ChangeOrderLifecycleActionsBar> createState() => _ChangeOrderLifecycleActionsBarState();
}

class _ChangeOrderLifecycleActionsBarState extends ConsumerState<_ChangeOrderLifecycleActionsBar> {
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
    final co = widget.changeOrder;
    final buttons = <Widget>[];

    if (co.isEditable && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Düzenle'),
        onPressed: _busy
            ? null
            : () => context.push(
                '/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/degisiklik-emirleri/${widget.changeOrderId}/duzenle'),
      ));
    }
    if (co.canSubmit && widget.canManage) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.send_outlined, size: 18),
        label: const Text('Gönder'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Gönder', 'Bu değişiklik emri onay için gönderilsin mi?');
                if (!ok) return;
                await _run(() => repo.submitSubcontractChangeOrder(widget.projectId, widget.changeOrderId));
              },
      ));
    }
    if (co.canCancel && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.cancel_outlined, size: 18, color: AppColors.danger),
        label: const Text('İptal Et', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('İptal Et', 'Bu değişiklik emri iptal edilsin mi?');
                if (!ok) return;
                await _run(() => repo.cancelSubcontractChangeOrder(widget.projectId, widget.changeOrderId));
              },
      ));
    }
    if (co.canApprove && widget.canApprove) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: const Text('Onayla'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Onayla',
                    'Bu değişiklik emri onaylansın mı? Onay, sözleşmenin güncel değerini ve taahhüt kaydını hemen değiştirir.');
                if (!ok) return;
                await _run(() => repo.approveSubcontractChangeOrder(widget.projectId, widget.changeOrderId));
              },
      ));
    }
    if (co.canReject && widget.canApprove) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.thumb_down_outlined, size: 18, color: AppColors.danger),
        label: const Text('Reddet', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Değişiklik Emrini Reddet');
                if (reason == null || reason.isEmpty) return;
                await _run(
                    () => repo.rejectSubcontractChangeOrder(widget.projectId, widget.changeOrderId, reason: reason));
              },
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

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
import '../domain/procurement.dart';

/// P3 — Satın Alma Talebi detayı. Artık yalnızca görüntüleme DEĞİL --
/// düzenleme + tam yaşam döngüsü aksiyonları (bkz. `_LifecycleActionsBar`).
class PurchaseRequestDetailScreen extends ConsumerWidget {
  const PurchaseRequestDetailScreen({
    super.key,
    required this.projectId,
    required this.prId,
  });
  final String projectId;
  final String prId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, prId: prId);
    final detailAsync = ref.watch(purchaseRequestDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.request.prNo),
          orElse: () => const Text('Satın Alma Talebi'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async =>
            ref.invalidate(purchaseRequestDetailProvider(args)),
        data: (context, detail) => _PurchaseRequestDetailBody(
          projectId: projectId,
          prId: prId,
          detail: detail,
        ),
      ),
    );
  }
}

class _PurchaseRequestDetailBody extends ConsumerWidget {
  const _PurchaseRequestDetailBody({
    required this.projectId,
    required this.prId,
    required this.detail,
  });
  final String projectId;
  final String prId;
  final ({PurchaseRequest request, List<PurchaseRequestItem> items}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, prId: prId);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.procurement.approve');

    void refreshAll() {
      ref.invalidate(purchaseRequestDetailProvider(args));
      ref.invalidate(projectPurchaseRequestsProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(
                detail.request.status,
                StatusRegistry.purchaseRequest,
              ),
              Text(
                Formatters.money(detail.request.estimatedTotal),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _LifecycleActionsBar(
            projectId: projectId,
            prId: prId,
            request: detail.request,
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
                  Text(
                    detail.request.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (detail.request.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(detail.request.description),
                  ],
                  const Divider(height: 20),
                  _Row(
                    'İhtiyaç Tarihi',
                    Formatters.date(detail.request.neededBy),
                  ),
                  _Row(
                    'Oluşturulma',
                    Formatters.dateTime(detail.request.createdAt),
                  ),
                  if (detail.request.submittedAt != null)
                    _Row(
                      'Gönderilme',
                      Formatters.dateTime(detail.request.submittedAt),
                    ),
                  if (detail.request.approvedAt != null)
                    _Row(
                      'Onaylanma',
                      Formatters.dateTime(detail.request.approvedAt),
                    ),
                  if (detail.request.rejectedAt != null)
                    _Row(
                      'Reddedilme',
                      Formatters.dateTime(detail.request.rejectedAt),
                    ),
                  if (detail.request.cancelledAt != null)
                    _Row(
                      'İptal',
                      Formatters.dateTime(detail.request.cancelledAt),
                    ),
                ],
              ),
            ),
          ),
          if (detail.request.rejectionReason.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ReasonCard(
              label: 'Red Gerekçesi',
              reason: detail.request.rejectionReason,
            ),
          ],
          if (detail.request.cancelReason.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ReasonCard(
              label: 'İptal Gerekçesi',
              reason: detail.request.cancelReason,
            ),
          ],
          const SizedBox(height: 16),
          const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (detail.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Kalem yok.', style: TextStyle(color: Colors.grey)),
            )
          else
            ...detail.items.map((item) => _PurchaseRequestItemTile(item: item)),
        ],
      ),
    );
  }
}

/// Düzenle/Gönder/Geri Çek/İptal `procurement.manage` -- Onayla/Reddet
/// `procurement.approve` (bkz. Phase 1: İptal PR'da `manage` grubunda,
/// PO'nun aksine).
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.prId,
    required this.request,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String prId;
  final PurchaseRequest request;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_LifecycleActionsBar> createState() =>
      _LifecycleActionsBarState();
}

class _LifecycleActionsBarState extends ConsumerState<_LifecycleActionsBar> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Onayla'),
          ),
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
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
    final pr = widget.request;
    final buttons = <Widget>[];

    if (pr.isEditable && widget.canManage) {
      buttons.add(
        OutlinedButton.icon(
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('Düzenle'),
          onPressed: _busy
              ? null
              : () => context.push(
                  '/projeler/${widget.projectId}/satin-alma/talepler/${widget.prId}/duzenle',
                ),
        ),
      );
    }
    if (pr.canSubmit && widget.canManage) {
      buttons.add(
        FilledButton.tonalIcon(
          icon: const Icon(Icons.send_outlined, size: 18),
          label: const Text('Gönder'),
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Gönder',
                    'Bu talep onay için gönderilsin mi?',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.submitPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canWithdraw && widget.canManage) {
      buttons.add(
        OutlinedButton.icon(
          icon: const Icon(Icons.undo, size: 18),
          label: const Text('Geri Çek'),
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Geri Çek',
                    'Bu talep taslağa geri çekilsin mi? Düzenlemeye devam edebilirsiniz.',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.withdrawPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canApprove && widget.canApprove) {
      buttons.add(
        FilledButton.tonalIcon(
          icon: const Icon(Icons.check_circle_outline, size: 18),
          label: const Text('Onayla'),
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Onayla',
                    'Bu talep onaylansın mı?',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.approvePurchaseRequest(
                      widget.projectId,
                      widget.prId,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canReject && widget.canApprove) {
      buttons.add(
        OutlinedButton.icon(
          icon: const Icon(
            Icons.thumb_down_outlined,
            size: 18,
            color: AppColors.danger,
          ),
          label: const Text(
            'Reddet',
            style: TextStyle(color: AppColors.danger),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.danger),
          ),
          onPressed: _busy
              ? null
              : () async {
                  final reason = await _promptReason('Talebi Reddet');
                  if (reason == null || reason.isEmpty) return;
                  await _run(
                    () => repo.rejectPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                      reason: reason,
                    ),
                  );
                },
        ),
      );
    }
    if (pr.canCancel && widget.canManage) {
      buttons.add(
        OutlinedButton.icon(
          icon: const Icon(
            Icons.cancel_outlined,
            size: 18,
            color: AppColors.danger,
          ),
          label: const Text(
            'İptal Et',
            style: TextStyle(color: AppColors.danger),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.danger),
          ),
          onPressed: _busy
              ? null
              : () async {
                  final reason = await _promptReason('Talebi İptal Et');
                  if (reason == null || reason.isEmpty) return;
                  await _run(
                    () => repo.cancelPurchaseRequest(
                      widget.projectId,
                      widget.prId,
                      reason: reason,
                    ),
                  );
                },
        ),
      );
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

class _PurchaseRequestItemTile extends StatelessWidget {
  const _PurchaseRequestItemTile({required this.item});
  final PurchaseRequestItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        title: Text(
          item.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit}'
          '${item.estimatedUnitCost != null ? '  ×  ${Formatters.money(item.estimatedUnitCost!)}' : ''}',
        ),
        trailing: Text(
          Formatters.money(item.estimatedTotal),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _ReasonCard extends StatelessWidget {
  const _ReasonCard({required this.label, required this.reason});
  final String label;
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 4),
            Text(reason),
          ],
        ),
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

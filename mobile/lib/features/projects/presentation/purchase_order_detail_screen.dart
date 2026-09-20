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

/// P3 — Satın Alma Siparişi detayı. Artık yalnızca görüntüleme DEĞİL --
/// düzenleme + tam yaşam döngüsü aksiyonları (bkz. `_LifecycleActionsBar`).
/// `commitments` artık gösterilir (bkz. Phase 1: PO onayı KALEM-başına,
/// onay-sonrası DEĞİŞMEZ bir commitment oluşturur -- Taşeron'un void-
/// yeniden-senkronize modelinden BİLİNÇLİ OLARAK FARKLI).
class PurchaseOrderDetailScreen extends ConsumerWidget {
  const PurchaseOrderDetailScreen({super.key, required this.projectId, required this.poId});
  final String projectId;
  final String poId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, poId: poId);
    final detailAsync = ref.watch(purchaseOrderDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.order.poNo),
          orElse: () => const Text('Satın Alma Siparişi'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(purchaseOrderDetailProvider(args)),
        data: (context, detail) => _PurchaseOrderDetailBody(projectId: projectId, poId: poId, detail: detail),
      ),
    );
  }
}

class _PurchaseOrderDetailBody extends ConsumerWidget {
  const _PurchaseOrderDetailBody({required this.projectId, required this.poId, required this.detail});
  final String projectId;
  final String poId;
  final ({PurchaseOrder order, List<PurchaseOrderItem> items, List<Commitment> commitments}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, poId: poId);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.approve');

    void refreshAll() {
      ref.invalidate(purchaseOrderDetailProvider(args));
      ref.invalidate(projectPurchaseOrdersProvider(projectId));
      // PO onayı/iptali proje maliyet kontrolüne YANSIR (commitment
      // oluşturur/voidler) -- bkz. Phase 1 doğrulaması.
      ref.invalidate(projectCostControlProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(detail.order.status, StatusRegistry.purchaseOrder),
              Text(Formatters.money(detail.order.total, currency: detail.order.currency),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ],
          ),
          const SizedBox(height: 12),
          _LifecycleActionsBar(
            projectId: projectId,
            poId: poId,
            order: detail.order,
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
                  Text(detail.order.supplierName ?? detail.order.supplierCode ?? '-',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Divider(height: 20),
                  _Row('Sipariş Tarihi', Formatters.date(detail.order.issueDate)),
                  _Row('Beklenen Teslimat', Formatters.date(detail.order.expectedDeliveryDate)),
                  if (detail.order.paymentTerms.isNotEmpty)
                    _Row('Ödeme Koşulları', detail.order.paymentTerms),
                  if (detail.order.deliveryAddress.isNotEmpty)
                    _Row('Teslimat Adresi', detail.order.deliveryAddress),
                  if (detail.order.sourceRfqId != null) _Row('Kaynak RFQ', detail.order.sourceRfqId!),
                  if (detail.order.sourceQuotationId != null)
                    _Row('Kaynak Teklif', detail.order.sourceQuotationId!),
                  if (detail.order.approvedAt != null)
                    _Row('Onaylanma', Formatters.dateTime(detail.order.approvedAt)),
                  if (detail.order.cancelledAt != null)
                    _Row('İptal', Formatters.dateTime(detail.order.cancelledAt)),
                  if (detail.order.closedAt != null)
                    _Row('Kapatılma', Formatters.dateTime(detail.order.closedAt)),
                ],
              ),
            ),
          ),
          if (detail.order.cancelReason.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ReasonCard(label: 'İptal Gerekçesi', reason: detail.order.cancelReason),
          ],
          if (detail.order.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ReasonCard(label: 'Notlar', reason: detail.order.notes),
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
            ...detail.items.map((item) => _PurchaseOrderItemTile(item: item, currency: detail.order.currency)),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _Row('Ara Toplam', Formatters.money(detail.order.subtotal, currency: detail.order.currency)),
                  _Row('KDV (%${detail.order.taxRate.toStringAsFixed(0)})',
                      Formatters.money(detail.order.tax, currency: detail.order.currency)),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Genel Toplam', style: TextStyle(color: Colors.grey)),
                        Text(Formatters.money(detail.order.total, currency: detail.order.currency),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (detail.commitments.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Maliyet Kontrolü Taahhütleri', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Onay ile kalem başına oluşturulan, onay-sonrası DEĞİŞMEZ taahhüt kayıtları.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            ...detail.commitments.map((c) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Text('${c.costCodeCode} — ${c.costCodeName}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(
                      Formatters.money(c.committedAmount, currency: c.currency),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        decoration: c.isVoided ? TextDecoration.lineThrough : null,
                        color: c.isVoided ? Colors.grey : null,
                      ),
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

/// Düzenle `procurement.manage` -- Onayla/İptal/Kapat `procurement.approve`
/// (bkz. Phase 1: PO'da Cancel de Approve iznine tabidir -- PR/RFQ'nun
/// AKSİNE, çünkü onaylı bir PO'yu iptal etmek commitment voidler).
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.poId,
    required this.order,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String poId;
  final PurchaseOrder order;
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
    final po = widget.order;
    final buttons = <Widget>[];

    if (po.isEditable && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Düzenle'),
        onPressed: _busy
            ? null
            : () => context.push('/projeler/${widget.projectId}/satin-alma/siparisler/${widget.poId}/duzenle'),
      ));
    }
    if (po.canApprove && widget.canApprove) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: const Text('Onayla'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm(
                    'Onayla', 'Bu sipariş onaylansın mı? Onay, her kalem için değişmez bir maliyet taahhüdü oluşturur.');
                if (!ok) return;
                await _run(() => repo.approvePurchaseOrder(widget.projectId, widget.poId));
              },
      ));
    }
    if (po.canCancel && widget.canApprove) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.cancel_outlined, size: 18, color: AppColors.danger),
        label: const Text('İptal Et', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final reason = await _promptReason('Siparişi İptal Et');
                if (reason == null || reason.isEmpty) return;
                await _run(() => repo.cancelPurchaseOrder(widget.projectId, widget.poId, reason: reason));
              },
      ));
    }
    if (po.canClose && widget.canApprove) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.archive_outlined, size: 18),
        label: const Text('Kapat'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Kapat', 'Bu sipariş kapatılsın mı? Bu terminal bir arşiv işaretidir.');
                if (!ok) return;
                await _run(() => repo.closePurchaseOrder(widget.projectId, widget.poId));
              },
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

class _PurchaseOrderItemTile extends StatelessWidget {
  const _PurchaseOrderItemTile({required this.item, required this.currency});
  final PurchaseOrderItem item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        title: Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit}'
          '  ×  ${Formatters.money(item.unitPrice, currency: currency)}',
        ),
        trailing: Text(Formatters.money(item.lineTotal, currency: currency),
            style: const TextStyle(fontWeight: FontWeight.w700)),
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
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.grey)),
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

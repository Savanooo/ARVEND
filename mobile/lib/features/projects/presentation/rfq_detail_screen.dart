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

/// P3 — RFQ detayı. Kalemler/tedarikçiler/teklifler/karşılaştırma/ödül
/// hepsi burada. Backend "en düşük"/"kazanan" alanı DÖNMEZ -- mobil
/// bir kazanan HESAPLAMAZ, yalnızca ham veriyi gösterir; karar Award
/// aksiyonuyla İNSAN tarafından verilir (bkz. domain/procurement.dart
/// `BidComparisonCell` yorumu).
class RFQDetailScreen extends ConsumerWidget {
  const RFQDetailScreen({super.key, required this.projectId, required this.rfqId});
  final String projectId;
  final String rfqId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, rfqId: rfqId);
    final detailAsync = ref.watch(rfqDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.rfq.rfqNo),
          orElse: () => const Text('RFQ'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(rfqDetailProvider(args)),
        data: (context, detail) => _RFQDetailBody(projectId: projectId, rfqId: rfqId, detail: detail),
      ),
    );
  }
}

class _RFQDetailBody extends ConsumerWidget {
  const _RFQDetailBody({required this.projectId, required this.rfqId, required this.detail});
  final String projectId;
  final String rfqId;
  final ({RFQ rfq, List<RFQItem> items, List<RFQSupplier> suppliers}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, rfqId: rfqId);
    final quotationsAsync = ref.watch(rfqQuotationsProvider(args));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.approve');
    final rfq = detail.rfq;

    void refreshAll() {
      ref.invalidate(rfqDetailProvider(args));
      ref.invalidate(rfqQuotationsProvider(args));
      ref.invalidate(projectRFQsProvider(projectId));
      ref.invalidate(bidComparisonProvider(args));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(rfq.status, StatusRegistry.rfq),
              if (rfq.isAwarded) const _AwardedBadge(),
            ],
          ),
          const SizedBox(height: 12),
          _LifecycleActionsBar(
            projectId: projectId,
            rfqId: rfqId,
            rfq: rfq,
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
                  Text(rfq.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Divider(height: 20),
                  _Row('Yayın Tarihi', Formatters.date(rfq.issueDate)),
                  if (rfq.dueDate != null) _Row('Son Yanıt Tarihi', Formatters.date(rfq.dueDate)),
                  if (rfq.purchaseRequestId != null) _Row('Kaynak Talep', rfq.purchaseRequestId!),
                  if (rfq.isAwarded) _Row('Ödüllendirilme', Formatters.dateTime(rfq.awardedAt)),
                ],
              ),
            ),
          ),
          if (rfq.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            _InfoCard(label: 'Notlar', text: rfq.notes),
          ],
          if (rfq.isAwarded && rfq.awardNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            _InfoCard(label: 'Ödül Notu', text: rfq.awardNotes),
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
            ...detail.items.map((it) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Text(it.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text('${it.quantity.toStringAsFixed(it.quantity.truncateToDouble() == it.quantity ? 0 : 2)} ${it.unit}'),
                  ),
                )),
          const SizedBox(height: 16),
          const Text('Davetli Tedarikçiler', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (detail.suppliers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Davetli tedarikçi yok.', style: TextStyle(color: Colors.grey)),
            )
          else
            ...detail.suppliers.map((s) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Text(s.supplierName.isNotEmpty ? s.supplierName : s.supplierCode,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(
                      s.responseStatus == 'responded' ? 'Yanıtladı' : 'Bekleniyor',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: s.responseStatus == 'responded' ? AppColors.success : Colors.grey,
                      ),
                    ),
                  ),
                )),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Teklifler', style: TextStyle(fontWeight: FontWeight.w700)),
              Row(
                children: [
                  if (quotationsAsync.valueOrNull != null && quotationsAsync.valueOrNull!.length >= 2)
                    TextButton.icon(
                      icon: const Icon(Icons.compare_arrows, size: 18),
                      label: const Text('Karşılaştır'),
                      onPressed: () => context.push('/projeler/$projectId/satin-alma/rfqlar/$rfqId/karsilastir'),
                    ),
                  if (rfq.status == RFQ.statusIssued && canManage)
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Teklif Ekle'),
                      onPressed: () async {
                        await context.push('/projeler/$projectId/satin-alma/rfqlar/$rfqId/teklifler/yeni');
                        refreshAll();
                      },
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          AsyncStateView(
            value: quotationsAsync,
            onRetry: () async => ref.invalidate(rfqQuotationsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Henüz teklif yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, quotations) => Column(
              children: quotations
                  .map((q) => _QuotationRow(
                        projectId: projectId,
                        rfqId: rfqId,
                        quotation: q,
                        rfq: rfq,
                        canManage: canManage,
                        canApprove: canApprove,
                        onChanged: refreshAll,
                      ))
                  .toList(),
            ),
          ),
          if (rfq.isAwarded) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add_shopping_cart_outlined, size: 18),
              label: const Text('Bu Tekliften Sipariş Oluştur'),
              onPressed: () => _createPoFromAward(context, ref),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _createPoFromAward(BuildContext context, WidgetRef ref) async {
    final rfq = detail.rfq;
    if (rfq.awardedQuotationId == null) return;
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final qDetail = await repo.quotationDetail(projectId, rfqId, rfq.awardedQuotationId!);
      final itemsById = {for (final it in detail.items) it.id: it};
      final prefillItems = qDetail.items
          .map((qi) {
            final rfqItem = itemsById[qi.rfqItemId];
            return PurchaseOrderItem(
              id: '',
              wbsNodeId: rfqItem?.wbsNodeId,
              costCodeId: '',
              budgetLineId: rfqItem?.budgetLineId,
              description: rfqItem?.description ?? qi.notes,
              quantity: qi.quantity,
              unit: rfqItem?.unit ?? '',
              unitPrice: qi.unitPrice,
              lineTotal: qi.lineTotal,
              sortOrder: 0,
            );
          })
          .toList();
      if (!context.mounted) return;
      context.push(
        '/projeler/$projectId/satin-alma/siparisler/yeni',
        extra: (
          supplierId: qDetail.quotation.supplierId,
          sourceRfqId: rfqId,
          sourceQuotationId: rfq.awardedQuotationId,
          items: prefillItems,
        ),
      );
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _AwardedBadge extends StatelessWidget {
  const _AwardedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
      child: const Text('Ödüllendirildi', style: TextStyle(color: AppColors.gold, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

class _QuotationRow extends ConsumerStatefulWidget {
  const _QuotationRow({
    required this.projectId,
    required this.rfqId,
    required this.quotation,
    required this.rfq,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String rfqId;
  final Quotation quotation;
  final RFQ rfq;
  final bool canManage;
  final bool canApprove;
  final VoidCallback onChanged;

  @override
  ConsumerState<_QuotationRow> createState() => _QuotationRowState();
}

class _QuotationRowState extends ConsumerState<_QuotationRow> {
  bool _busy = false;

  bool get _isWinner => widget.quotation.id == widget.rfq.awardedQuotationId;

  Future<void> _award() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bu Teklifi Ödüllendir'),
        content: Text(
            '${widget.quotation.supplierName ?? widget.quotation.supplierId} tedarikçisinin teklifi ödüllendirilsin mi? '
            'RFQ kapanır, diğer teklifler otomatik reddedilmez.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Ödüllendir')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(projectsRepositoryProvider).awardRFQ(widget.projectId, widget.rfqId, quotationId: widget.quotation.id);
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Teklifi Sil'),
        content: const Text('Bu teklif kalıcı olarak silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(projectsRepositoryProvider).deleteQuotation(widget.projectId, widget.rfqId, widget.quotation.id);
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.quotation;
    final rfqOpen = widget.rfq.status == RFQ.statusIssued;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: _isWinner ? AppColors.gold.withValues(alpha: 0.06) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    q.supplierName ?? q.supplierId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, color: _isWinner ? AppColors.gold : null),
                  ),
                ),
                Text(Formatters.money(q.total, currency: q.currency), style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            if (q.deliveryDays != null || q.paymentTerms.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    if (q.deliveryDays != null) '${q.deliveryDays} gün teslimat',
                    if (q.paymentTerms.isNotEmpty) q.paymentTerms,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            if (_isWinner)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Ödüllendirilen teklif', style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w700)),
              ),
            if (rfqOpen) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (widget.canManage)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => context.push('/projeler/${widget.projectId}/satin-alma/rfqlar/${widget.rfqId}/teklifler/${q.id}/duzenle'),
                      child: const Text('Düzenle'),
                    ),
                  if (widget.canManage)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
                      onPressed: _busy ? null : _delete,
                      child: const Text('Sil'),
                    ),
                  if (widget.canApprove)
                    FilledButton.tonal(
                      onPressed: _busy ? null : _award,
                      child: const Text('Ödüllendir'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Düzenle/Yayınla/Kapat/İptal `procurement.manage` -- Ödül `procurement.
/// approve` (bkz. Phase 1: değişik izin gruplarında; RFQ Cancel PR ile AYNI
/// şekilde `manage`dedir ve gerekçe İSTEMEZ, backend'e özgü bir istisna).
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.rfqId,
    required this.rfq,
    required this.canManage,
    required this.canApprove,
    required this.onChanged,
  });

  final String projectId;
  final String rfqId;
  final RFQ rfq;
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

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(projectsRepositoryProvider);
    final rfq = widget.rfq;
    final buttons = <Widget>[];

    if (rfq.isEditable && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Düzenle'),
        onPressed: _busy
            ? null
            : () => context.push('/projeler/${widget.projectId}/satin-alma/rfqlar/${widget.rfqId}/duzenle'),
      ));
    }
    if (rfq.canIssue && widget.canManage) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.send_outlined, size: 18),
        label: const Text('Yayınla'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Yayınla',
                    'Bu RFQ yayınlansın mı? Bu, salt DB içi bir durum geçişidir -- hiçbir e-posta/bildirim GÖNDERİLMEZ.');
                if (!ok) return;
                await _run(() => repo.issueRFQ(widget.projectId, widget.rfqId));
              },
      ));
    }
    if (rfq.canClose && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.close, size: 18),
        label: const Text('Kapat (Ödülsüz)'),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('Kapat', 'Bu RFQ ödül vermeden kapatılsın mı?');
                if (!ok) return;
                await _run(() => repo.closeRFQ(widget.projectId, widget.rfqId));
              },
      ));
    }
    if (rfq.canCancel && widget.canManage) {
      buttons.add(OutlinedButton.icon(
        icon: const Icon(Icons.cancel_outlined, size: 18, color: AppColors.danger),
        label: const Text('İptal Et', style: TextStyle(color: AppColors.danger)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy
            ? null
            : () async {
                final ok = await _confirm('İptal Et', 'Bu RFQ iptal edilsin mi?');
                if (!ok) return;
                await _run(() => repo.cancelRFQ(widget.projectId, widget.rfqId));
              },
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.text});
  final String label;
  final String text;

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
            Text(text),
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

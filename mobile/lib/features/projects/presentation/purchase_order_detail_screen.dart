import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_status_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_financial_summary.dart';
import '../../../core/widgets/app_lifecycle_actions.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/delete_request.dart' show showNoteDialog;
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import 'purchase_cost_decision.dart';
import 'purchase_receipt_form_screen.dart' show formatReceiptQty;

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

    return AppPageScaffold(
      title: detailAsync.maybeWhen(
        data: (d) => Text(d.order.poNo),
        orElse: () => const Text('Satın Alma Siparişi'),
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
  final PurchaseOrderDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, poId: poId);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.approve');
    final canReceive = user == null || user.permissions.isEmpty || user.hasPermission(kProcurementReceivePermission);
    final order = detail.order;
    final showReceipts = order.status == PurchaseOrder.statusApproved || order.status == PurchaseOrder.statusClosed;

    void refreshAll() {
      ref.invalidate(purchaseOrderDetailProvider(args));
      ref.invalidate(projectPurchaseOrdersProvider(projectId));
      // Teslim / sipariş bağı kârlılıktaki "teslim alınmış, maliyeti
      // girilmemiş" tutarı değiştirir.
      ref.invalidate(projectFinancialSummaryProvider(projectId));
      // PO onayı/iptali proje maliyet kontrolüne YANSIR (commitment
      // oluşturur/voidler) -- bkz. Phase 1 doğrulaması.
      ref.invalidate(projectCostControlProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const AppSectionHeader(title: 'Sipariş'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    StatusRegistry.build(order.status, StatusRegistry.purchaseOrder),
                    Flexible(
                      child: MoneyText(
                        order.total,
                        currency: order.currency,
                        style: AppTypography.pageTitle,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(order.supplierName ?? order.supplierCode ?? '-', style: AppTypography.cardTitle),
                const SizedBox(height: AppSpacing.xs),
                AppDataRow(label: 'Sipariş No', value: order.poNo),
                if (order.sourceRfqId != null) AppDataRow(label: 'Kaynak RFQ', value: order.sourceRfqId!),
                if (order.sourceQuotationId != null)
                  AppDataRow(label: 'Kaynak Teklif', value: order.sourceQuotationId!),
              ],
            ),
          ),
          if (order.cancelReason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _ReasonCard(label: 'İptal Gerekçesi', reason: order.cancelReason),
          ],
          if (order.status != PurchaseOrder.statusCancelled) ...[
            const SizedBox(height: AppSpacing.lg),
            const AppSectionHeader(title: 'Proje Maliyeti'),
            PurchaseCostCard(
              included: order.includeInProjectCost,
              cost: order.projectCost,
              currency: order.currency,
              onChange: canApprove && order.canChangeProjectCost
                  ? () => _changePurchaseOrderCost(context, ref, projectId, order, refreshAll)
                  : null,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _LifecycleActionsBar(
            projectId: projectId,
            poId: poId,
            order: order,
            canManage: canManage,
            canApprove: canApprove,
            receiptSummary: detail.receiptSummary,
            onChanged: refreshAll,
          ),
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Kalemler'),
          const SizedBox(height: AppSpacing.sm),
          if (detail.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('Kalem yok.', style: AppTypography.metadata),
            )
          else
            ...detail.items.map((item) => _PurchaseOrderItemTile(item: item, currency: order.currency, showReceipt: showReceipts)),
          const SizedBox(height: AppSpacing.sm),
          AppFinancialSummary(
            rows: [
              AppDataRow(label: 'Ara Toplam', value: Formatters.money(order.subtotal, currency: order.currency)),
              AppDataRow(
                label: 'KDV (%${order.taxRate.toStringAsFixed(0)})',
                value: Formatters.money(order.tax, currency: order.currency),
              ),
              const Divider(),
              AppDataRow(
                label: 'Genel Toplam',
                value: Formatters.money(order.total, currency: order.currency),
                emphasize: true,
              ),
            ],
          ),
          if (showReceipts) ...[
            const SizedBox(height: AppSpacing.xl),
            _ReceiptsSection(
              projectId: projectId,
              order: order,
              items: detail.items,
              receipts: detail.receipts,
              summary: detail.receiptSummary,
              canReceive: canReceive,
              onChanged: refreshAll,
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Teslimat / Ticari Bilgiler'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(
              children: [
                AppDataRow(label: 'Sipariş Tarihi', value: Formatters.date(order.issueDate)),
                AppDataRow(label: 'Beklenen Teslimat', value: Formatters.date(order.expectedDeliveryDate)),
                if (order.paymentTerms.isNotEmpty)
                  AppDataRow(label: 'Ödeme Koşulları', value: order.paymentTerms),
                if (order.deliveryAddress.isNotEmpty)
                  AppDataRow(label: 'Teslimat Adresi', value: order.deliveryAddress),
                if (order.approvedAt != null)
                  AppDataRow(label: 'Onaylanma', value: Formatters.dateTime(order.approvedAt)),
                if (order.cancelledAt != null)
                  AppDataRow(label: 'İptal', value: Formatters.dateTime(order.cancelledAt)),
                if (order.closedAt != null)
                  AppDataRow(label: 'Kapatılma', value: Formatters.dateTime(order.closedAt)),
              ],
            ),
          ),
          if (order.notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            _ReasonCard(label: 'Notlar', reason: order.notes),
          ],
          if (detail.commitments.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: 'Taahhüt Etkisi'),
            const SizedBox(height: 2),
            const Text(
              'Onay ile kalem başına oluşturulan, onay-sonrası değişmez taahhüt kayıtları.',
              style: AppTypography.helper,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                children: [
                  for (var i = 0; i < detail.commitments.length; i++) ...[
                    if (i > 0) const Divider(height: AppSpacing.lg),
                    _CommitmentRow(commitment: detail.commitments[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Açık siparişin maliyet kararını değiştirir (`projects.procurement.approve`).
Future<void> _changePurchaseOrderCost(
  BuildContext context,
  WidgetRef ref,
  String projectId,
  PurchaseOrder order,
  VoidCallback onChanged,
) async {
  final c = order.projectCost;
  final choice = await showPurchaseCostSheet(
    context,
    title: 'Maliyet Kararı',
    amount: (c != null && c.potential > 0) ? c.potential : order.total,
    currency: order.currency,
    initialInclude: order.includeInProjectCost,
    confirmLabel: 'Kaydet',
  );
  if (choice == null || choice.include == order.includeInProjectCost) return;
  try {
    await ref
        .read(projectsRepositoryProvider)
        .setPurchaseOrderCost(projectId, order.id, includeInProjectCost: choice.include);
    onChanged();
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
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
    this.receiptSummary = const PurchaseReceiptSummary(),
    required this.onChanged,
  });

  final String projectId;
  final String poId;
  final PurchaseOrder order;
  final bool canManage;
  final bool canApprove;
  final PurchaseReceiptSummary receiptSummary;
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
    final actions = <AppLifecycleAction>[];

    if (po.isEditable && widget.canManage) {
      actions.add(AppLifecycleAction(
        label: 'Düzenle',
        icon: Icons.edit_outlined,
        onPressed: _busy
            ? null
            : () => context.push('/projeler/${widget.projectId}/satin-alma/siparisler/${widget.poId}/duzenle'),
      ));
    }
    if (po.canApprove && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'Onayla',
        icon: Icons.check_circle_outline,
        primary: true,
        onPressed: _busy
            ? null
            : () async {
                // Onaylı sipariş proje maliyetine girer (backend migration
                // 0078); karar talepten devralınır, burada değiştirilebilir.
                final choice = await showPurchaseCostSheet(
                  context,
                  title: 'Siparişi Onayla',
                  note: po.purchaseRequestId != null
                      ? 'Sipariş, talebin tahmini tutarının yerine maliyete girer. Onay, her kalem için değişmez bir maliyet taahhüdü de oluşturur.'
                      : 'Onay, her kalem için değişmez bir maliyet taahhüdü de oluşturur.',
                  amount: po.projectCost?.potential ?? po.total,
                  currency: po.currency,
                  initialInclude: po.includeInProjectCost,
                );
                if (choice == null) return;
                await _run(() => repo.approvePurchaseOrder(
                      widget.projectId,
                      widget.poId,
                      includeInProjectCost: choice.include,
                    ));
              },
      ));
    }
    if (po.canCancel && widget.canApprove) {
      actions.add(AppLifecycleAction(
        label: 'İptal Et',
        icon: Icons.cancel_outlined,
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
      actions.add(AppLifecycleAction(
        label: 'Kapat',
        icon: Icons.archive_outlined,
        primary: true,
        onPressed: _busy
            ? null
            : () async {
                // Teslim kaydı varsa gelmeyen kısım taahhütten çıkar (backend
                // migration 0074); yoksa taahhüt olduğu gibi kalır.
                final s = widget.receiptSummary;
                final message = po.hasReceipts
                    ? 'Sipariş kapatılır, yeni teslim girilemez. Gelmeyen kısım taahhütten çıkar; teslim alınan '
                        '${Formatters.money(s.acceptedTotal, currency: po.currency)} kalır.'
                    : 'Bu siparişte teslim kaydı yok: kapatınca tamamı teslim alınmış sayılır ve taahhüt olduğu gibi '
                        'kalır. Mal gelmeyecekse siparişi iptal edin.';
                final ok = await _confirm('Kapat', message);
                if (!ok) return;
                await _run(() => repo.closePurchaseOrder(widget.projectId, widget.poId));
              },
      ));
    }

    return AppLifecycleActions(actions: actions);
  }
}

class _PurchaseOrderItemTile extends StatelessWidget {
  const _PurchaseOrderItemTile({required this.item, required this.currency, this.showReceipt = false});
  final PurchaseOrderItem item;
  final String currency;

  /// Onaylı/kapatılmış siparişte kalem başına kabul / red / bekleyen.
  final bool showReceipt;

  @override
  Widget build(BuildContext context) {
    final qty = item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2);
    final base = '$qty ${item.unit}  ×  ${Formatters.money(item.unitPrice, currency: currency)}';
    final received = showReceipt && item.acceptedQuantity != null
        ? 'Kabul ${formatReceiptQty(item.acceptedQuantity!)} · Red ${formatReceiptQty(item.rejectedQuantity ?? 0)} · '
            'Bekleyen ${formatReceiptQty(item.waitingQuantity ?? 0)}'
        : null;
    return AppListCard(
      title: item.description,
      subtitle: base,
      footer: received == null
          ? null
          : Text(received, key: ValueKey('po-item-received-${item.id}'), style: AppTypography.metadata),
      trailing: MoneyText(item.lineTotal, currency: currency, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

/// Teslim alma (backend migration 0074): özet (teslim alınan, faturası
/// girilen, maliyeti girilmemiş), "Teslim Al" ve teslim listesi. Teslime
/// dokununca ayrıntı; onaylı siparişte gerekçeyle iptal edilebilir.
class _ReceiptsSection extends ConsumerWidget {
  const _ReceiptsSection({
    required this.projectId,
    required this.order,
    required this.items,
    required this.receipts,
    required this.summary,
    required this.canReceive,
    required this.onChanged,
  });

  final String projectId;
  final PurchaseOrder order;
  final List<PurchaseOrderItem> items;
  final List<PurchaseReceipt> receipts;
  final PurchaseReceiptSummary summary;
  final bool canReceive;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cur = order.currency;
    final statusText = switch (summary.status) {
      kReceiptComplete => 'Teslim alındı',
      kReceiptPartial => 'Kısmi teslim',
      _ => 'Teslim yok',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: 'Teslim Alma'),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Column(
            children: [
              AppDataRow(label: 'Durum', value: statusText),
              AppDataRow(label: 'Teslim alınan (KDV dahil)', value: Formatters.money(summary.acceptedTotal, currency: cur)),
              AppDataRow(label: 'Faturası girilen', value: Formatters.money(summary.costedTotal, currency: cur)),
              AppDataRow(
                label: 'Maliyeti girilmemiş',
                value: Formatters.money(summary.receivedNotCosted, currency: cur),
                valueColor: summary.receivedNotCosted > 0 ? AppStatusColors.warning : null,
              ),
            ],
          ),
        ),
        if (summary.receivedNotCosted > 0)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              'Faturayı masraf olarak girerken bu siparişi seçin; maliyeti girilmemiş tutar düşer.',
              style: AppTypography.helper,
            ),
          ),
        if (canReceive && order.canReceive) ...[
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            key: const ValueKey('po-receive'),
            icon: const Icon(Icons.local_shipping_outlined),
            label: const Text('Teslim Al'),
            onPressed: () async {
              final saved =
                  await context.push<bool>('/projeler/$projectId/satin-alma/siparisler/${order.id}/teslim');
              if (saved == true) onChanged();
            },
          ),
        ],
        if (receipts.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          for (final r in receipts)
            _ReceiptTile(
              receipt: r,
              items: items,
              onTap: () => _showReceipt(context, ref, r),
            ),
        ],
      ],
    );
  }

  Future<void> _showReceipt(BuildContext context, WidgetRef ref, PurchaseReceipt r) async {
    final canVoid = canReceive && order.canReceive && !r.isVoided;
    final voided = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ReceiptDetailSheet(
        projectId: projectId,
        receipt: r,
        items: items,
        canVoid: canVoid,
      ),
    );
    if (voided == true) onChanged();
  }
}

String _receiptLineText(PurchaseReceiptItem line, List<PurchaseOrderItem> items) {
  PurchaseOrderItem? item;
  for (final i in items) {
    if (i.id == line.purchaseOrderItemId) item = i;
  }
  final unit = (item?.unit ?? '').isEmpty ? '' : ' ${item!.unit}';
  final parts = <String>[
    if (line.acceptedQuantity > 0) 'kabul ${formatReceiptQty(line.acceptedQuantity)}$unit',
    if (line.rejectedQuantity > 0)
      'red ${formatReceiptQty(line.rejectedQuantity)}$unit'
          '${line.rejectionReason.isEmpty ? '' : ' (${line.rejectionReason})'}',
  ];
  return '${item?.description ?? 'Kalem'}: ${parts.join(', ')}';
}

class _ReceiptTile extends StatelessWidget {
  const _ReceiptTile({required this.receipt, required this.items, required this.onTap});
  final PurchaseReceipt receipt;
  final List<PurchaseOrderItem> items;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final head = [
      'Teslim ${r.sequenceNo}',
      Formatters.date(r.receivedDate),
      if (r.deliveryNoteNo.isNotEmpty) 'İrsaliye ${r.deliveryNoteNo}',
      r.destinationLabel,
    ].join(' · ');
    return Opacity(
      opacity: r.isVoided ? 0.6 : 1,
      child: AppListCard(
        key: ValueKey('po-receipt-${r.id}'),
        title: head,
        subtitle: [for (final l in r.items) _receiptLineText(l, items)].join(' · '),
        footer: r.isVoided
            ? Text(
                'İptal edildi${r.voidReason.isEmpty ? '' : ': ${r.voidReason}'}',
                style: AppTypography.metadata.copyWith(color: AppStatusColors.error),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}

class _ReceiptDetailSheet extends ConsumerStatefulWidget {
  const _ReceiptDetailSheet({required this.projectId, required this.receipt, required this.items, required this.canVoid});
  final String projectId;
  final PurchaseReceipt receipt;
  final List<PurchaseOrderItem> items;
  final bool canVoid;

  @override
  ConsumerState<_ReceiptDetailSheet> createState() => _ReceiptDetailSheetState();
}

class _ReceiptDetailSheetState extends ConsumerState<_ReceiptDetailSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _void() async {
    // Denetleyiciyi pencerenin kendisi tutar (kapanış animasyonu bitmeden
    // atılırsa alan çöküyordu).
    final reason = await showNoteDialog(
      context,
      title: 'Teslimi İptal Et',
      message: 'Teslim iptal edilir; kabul ve red miktarları siparişten düşer. Kayıt silinmez.',
      label: 'İptal nedeni',
      confirm: 'İptal Et',
      keyName: 'receipt-void-reason',
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(projectsRepositoryProvider).voidPurchaseReceipt(widget.projectId, widget.receipt.id, reason: reason);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(const SnackBar(content: Text('Teslim iptal edildi.')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Bu işlem için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.receipt;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Teslim ${r.sequenceNo}', style: AppTypography.sectionTitle),
            const SizedBox(height: AppSpacing.md),
            AppDataRow(label: 'Tarih', value: Formatters.date(r.receivedDate)),
            AppDataRow(label: 'İrsaliye no', value: r.deliveryNoteNo.isEmpty ? '—' : r.deliveryNoteNo),
            AppDataRow(label: 'Teslim yeri', value: r.destinationLabel),
            if (r.createdByName.isNotEmpty) AppDataRow(label: 'Teslim alan', value: r.createdByName),
            if (r.notes.isNotEmpty) AppDataRow(label: 'Not', value: r.notes, multiline: true),
            for (final l in r.items) AppDataRow(label: 'Kalem', value: _receiptLineText(l, widget.items), multiline: true),
            if (r.isVoided)
              AppDataRow(label: 'İptal', value: r.voidReason.isEmpty ? 'İptal edildi' : r.voidReason, multiline: true),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(_error!, style: AppTypography.error),
            ],
            if (widget.canVoid) ...[
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(
                key: const ValueKey('receipt-void'),
                icon: const Icon(Icons.block_outlined),
                label: const Text('İptal Et'),
                onPressed: _busy ? null : _void,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bir taahhüdün tek satırlık, kullanıcıya-yönelik özeti -- ham `status`/
/// `sourceType` gibi backend-içi alanlar KASITLI OLARAK gösterilmez (bkz.
/// Faz 3 modül talimatı). Yalnızca maliyet kodu + tutar (+ varsa açıklama).
class _CommitmentRow extends StatelessWidget {
  const _CommitmentRow({required this.commitment});
  final Commitment commitment;

  @override
  Widget build(BuildContext context) {
    final c = commitment;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppDataRow(
            label: '${c.costCodeCode} — ${c.costCodeName}',
            value: Formatters.money(c.committedAmount, currency: c.currency),
            valueColor: c.isVoided ? AppStatusColors.neutral : null,
          ),
          if (c.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(c.description, style: AppTypography.helper, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (c.isVoided)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('İptal ile geçersiz kılındı', style: AppTypography.helper.copyWith(color: AppStatusColors.neutral)),
            ),
        ],
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
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(reason, style: AppTypography.body),
        ],
      ),
    );
  }
}

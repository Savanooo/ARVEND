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
import '../../../core/widgets/money_text.dart';
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
  final ({PurchaseOrder order, List<PurchaseOrderItem> items, List<Commitment> commitments}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, poId: poId);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.procurement.approve');
    final order = detail.order;

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
          const SizedBox(height: AppSpacing.lg),
          _LifecycleActionsBar(
            projectId: projectId,
            poId: poId,
            order: order,
            canManage: canManage,
            canApprove: canApprove,
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
            ...detail.items.map((item) => _PurchaseOrderItemTile(item: item, currency: order.currency)),
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
                final ok = await _confirm(
                    'Onayla', 'Bu sipariş onaylansın mı? Onay, her kalem için değişmez bir maliyet taahhüdü oluşturur.');
                if (!ok) return;
                await _run(() => repo.approvePurchaseOrder(widget.projectId, widget.poId));
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
                final ok = await _confirm('Kapat', 'Bu sipariş kapatılsın mı? Bu terminal bir arşiv işaretidir.');
                if (!ok) return;
                await _run(() => repo.closePurchaseOrder(widget.projectId, widget.poId));
              },
      ));
    }

    return AppLifecycleActions(actions: actions);
  }
}

class _PurchaseOrderItemTile extends StatelessWidget {
  const _PurchaseOrderItemTile({required this.item, required this.currency});
  final PurchaseOrderItem item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final qty = item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2);
    return AppListCard(
      title: item.description,
      subtitle: '$qty ${item.unit}  ×  ${Formatters.money(item.unitPrice, currency: currency)}',
      trailing: MoneyText(item.lineTotal, currency: currency, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
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

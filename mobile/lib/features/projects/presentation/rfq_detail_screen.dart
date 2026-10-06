import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_lifecycle_actions.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import 'purchase_order_form_screen.dart' show PurchaseOrderPrefill;

/// P3 — RFQ detayı. Kalemler/tedarikçiler/teklifler/karşılaştırma/ödül
/// hepsi burada. Backend "en düşük"/"kazanan" alanı DÖNMEZ -- mobil
/// bir kazanan HESAPLAMAZ, yalnızca ham veriyi gösterir; karar Award
/// aksiyonuyla İNSAN tarafından verilir (bkz. domain/procurement.dart
/// `BidComparisonCell` yorumu).
class RFQDetailScreen extends ConsumerWidget {
  const RFQDetailScreen({
    super.key,
    required this.projectId,
    required this.rfqId,
  });
  final String projectId;
  final String rfqId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, rfqId: rfqId);
    final detailAsync = ref.watch(rfqDetailProvider(args));

    return AppPageScaffold(
      title: detailAsync.maybeWhen(
        data: (d) => Text(d.rfq.rfqNo),
        orElse: () => const Text('RFQ'),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(rfqDetailProvider(args)),
        data: (context, detail) =>
            _RFQDetailBody(projectId: projectId, rfqId: rfqId, detail: detail),
      ),
    );
  }
}

class _RFQDetailBody extends ConsumerWidget {
  const _RFQDetailBody({
    required this.projectId,
    required this.rfqId,
    required this.detail,
  });
  final String projectId;
  final String rfqId;
  final ({RFQ rfq, List<RFQItem> items, List<RFQSupplier> suppliers}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, rfqId: rfqId);
    final quotationsAsync = ref.watch(rfqQuotationsProvider(args));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.procurement.manage');
    final canApprove =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.procurement.approve');
    final rfq = detail.rfq;
    final showActions =
        rfq.isAwarded ||
        ((rfq.isEditable || rfq.canIssue || rfq.canClose || rfq.canCancel) &&
            canManage);

    void refreshAll() {
      ref.invalidate(rfqDetailProvider(args));
      ref.invalidate(rfqQuotationsProvider(args));
      ref.invalidate(projectRFQsProvider(projectId));
      ref.invalidate(bidComparisonProvider(args));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const AppSectionHeader(title: 'RFQ Özeti'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rfq.title, style: AppTypography.cardTitle),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    StatusRegistry.build(rfq.status, StatusRegistry.rfq),
                    if (rfq.isAwarded) StatusRegistry.awardedQuotation,
                  ],
                ),
                const Divider(height: AppSpacing.xl),
                AppDataRow(
                  label: 'Yayın Tarihi',
                  value: Formatters.date(rfq.issueDate),
                ),
                if (rfq.dueDate != null)
                  AppDataRow(
                    label: 'Son Yanıt Tarihi',
                    value: Formatters.date(rfq.dueDate),
                  ),
                if (rfq.purchaseRequestId != null)
                  AppDataRow(
                    label: 'Kaynak Talep',
                    value: rfq.purchaseRequestId!,
                  ),
                if (rfq.isAwarded)
                  AppDataRow(
                    label: 'Ödüllendirilme',
                    value: Formatters.dateTime(rfq.awardedAt),
                  ),
              ],
            ),
          ),
          if (rfq.notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _InfoCard(label: 'Notlar', text: rfq.notes),
          ],
          if (rfq.isAwarded && rfq.awardNotes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _InfoCard(label: 'Ödül Notu', text: rfq.awardNotes),
          ],
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Tedarikçiler'),
          const SizedBox(height: AppSpacing.sm),
          if (detail.suppliers.isEmpty)
            const EmptyStateView(
              message: 'Davetli tedarikçi yok.',
              icon: Icons.groups_outlined,
            )
          else
            ...detail.suppliers.map(
              (s) => AppListCard(
                title: s.supplierName.isNotEmpty
                    ? s.supplierName
                    : s.supplierCode,
                trailing: StatusBadge(
                  label: s.responseStatus == 'responded'
                      ? 'Yanıtladı'
                      : 'Bekleniyor',
                  tone: s.responseStatus == 'responded'
                      ? StatusTone.success
                      : StatusTone.muted,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Kalemler'),
          const SizedBox(height: AppSpacing.sm),
          if (detail.items.isEmpty)
            const EmptyStateView(
              message: 'Kalem yok.',
              icon: Icons.inventory_2_outlined,
            )
          else
            ...detail.items.map(
              (it) => AppListCard(
                title: it.description,
                trailing: Text(
                  '${it.quantity.toStringAsFixed(it.quantity.truncateToDouble() == it.quantity ? 0 : 2)} ${it.unit}',
                  style: AppTypography.body.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(
            title: 'Teklifler',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (quotationsAsync.valueOrNull != null &&
                    quotationsAsync.valueOrNull!.length >= 2)
                  TextButton.icon(
                    icon: const Icon(Icons.compare_arrows, size: 18),
                    label: const Text('Karşılaştır'),
                    onPressed: () => context.push(
                      '/projeler/$projectId/satin-alma/rfqlar/$rfqId/karsilastir',
                    ),
                  ),
                if (rfq.canAward && canManage)
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Teklif Ekle'),
                    onPressed: () async {
                      await context.push(
                        '/projeler/$projectId/satin-alma/rfqlar/$rfqId/teklifler/yeni',
                      );
                      refreshAll();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AsyncStateView(
            value: quotationsAsync,
            onRetry: () async => ref.invalidate(rfqQuotationsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const EmptyStateView(
              message: 'Henüz teklif yok.',
              icon: Icons.request_quote_outlined,
            ),
            data: (context, quotations) => Column(
              children: quotations
                  .map(
                    (q) => _QuotationRow(
                      projectId: projectId,
                      rfqId: rfqId,
                      quotation: q,
                      rfq: rfq,
                      canManage: canManage,
                      canApprove: canApprove,
                      onChanged: refreshAll,
                    ),
                  )
                  .toList(),
            ),
          ),
          if (showActions) ...[
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: 'İşlemler'),
            const SizedBox(height: AppSpacing.sm),
            _LifecycleActionsBar(
              projectId: projectId,
              rfqId: rfqId,
              rfq: rfq,
              canManage: canManage,
              onChanged: refreshAll,
            ),
            if (rfq.isAwarded && canManage) ...[
              const SizedBox(height: AppSpacing.sm),
              PrimaryButton(
                icon: Icons.add_shopping_cart_outlined,
                label: 'Bu Tekliften Sipariş Oluştur',
                onPressed: () => _createPoFromAward(context, ref),
              ),
            ],
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
      final qDetail = await repo.quotationDetail(
        projectId,
        rfqId,
        rfq.awardedQuotationId!,
      );
      // Maliyet kodu, KDV oranı ve iskonto da taşınır -- eskiden maliyet
      // kodu boş, KDV %20 sabit geliyor, iskonto atılıyordu; sipariş toplamı
      // kazanan teklifle tutmuyordu (bkz. purchaseOrderItemsFromAward).
      final quotation = qDetail.quotation;
      final prefillItems = purchaseOrderItemsFromAward(
        rfqItems: detail.items,
        quotationItems: qDetail.items,
        discount: quotation.discount,
      );
      if (!context.mounted) return;
      final PurchaseOrderPrefill prefill = (
        supplierId: quotation.supplierId,
        sourceRfqId: rfqId,
        sourceQuotationId: rfq.awardedQuotationId,
        items: prefillItems,
        taxRate: quotation.taxRate,
        discount: quotation.discount,
      );
      context.push('/projeler/$projectId/satin-alma/siparisler/yeni', extra: prefill);
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
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
          'RFQ kapanır, diğer teklifler otomatik reddedilmez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Ödüllendir'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(projectsRepositoryProvider)
          .awardRFQ(
            widget.projectId,
            widget.rfqId,
            quotationId: widget.quotation.id,
          );
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(projectsRepositoryProvider)
          .deleteQuotation(widget.projectId, widget.rfqId, widget.quotation.id);
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.quotation;
    // `canAward` == `status == statusIssued` -- kalemin kendisi RFQ'nun
    // hâlâ açık (teklif/düzenleme/ödül kabul eden) olup olmadığını sorar,
    // domain'de bu KOŞULU zaten birebir karşılayan getter budur.
    final rfqOpenForAward = widget.rfq.canAward;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      color: _isWinner ? AppColors.success.withValues(alpha: 0.06) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  q.supplierName ?? q.supplierId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.cardTitle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              MoneyText(
                q.total,
                currency: q.currency,
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 2,
            children: [
              if (q.validUntil != null)
                Text(
                  'Geçerlilik: ${Formatters.date(q.validUntil)}',
                  style: AppTypography.metadata,
                ),
              if (q.deliveryDays != null)
                Text(
                  '${q.deliveryDays} gün teslimat',
                  style: AppTypography.metadata,
                ),
              if (q.paymentTerms.isNotEmpty)
                Text(q.paymentTerms, style: AppTypography.metadata),
            ],
          ),
          if (_isWinner) ...[
            const SizedBox(height: AppSpacing.xs),
            StatusRegistry.awardedQuotation,
          ],
          if (rfqOpenForAward) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                if (widget.canManage)
                  SecondaryButton(
                    label: 'Düzenle',
                    onPressed: _busy
                        ? null
                        : () => context.push(
                            '/projeler/${widget.projectId}/satin-alma/rfqlar/${widget.rfqId}/teklifler/${q.id}/duzenle',
                          ),
                  ),
                if (widget.canManage)
                  SecondaryButton(
                    label: 'Sil',
                    onPressed: _busy ? null : _delete,
                  ),
                if (widget.canApprove)
                  PrimaryButton(
                    label: 'Ödüllendir',
                    onPressed: _busy ? null : _award,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Düzenle/Yayınla/Kapat/İptal `procurement.manage` -- Ödül `procurement.
/// approve` (bkz. Phase 1: değişik izin gruplarında; RFQ Cancel PR ile AYNI
/// şekilde `manage`dedir ve gerekçe İSTEMEZ, backend'e özgü bir istisna).
/// Ödül aksiyonu belirli bir teklife (quotationId) bağlı olduğundan burada
/// DEĞİL, her teklif satırında (`_QuotationRow`) sunulur.
class _LifecycleActionsBar extends ConsumerStatefulWidget {
  const _LifecycleActionsBar({
    required this.projectId,
    required this.rfqId,
    required this.rfq,
    required this.canManage,
    required this.onChanged,
  });

  final String projectId;
  final String rfqId;
  final RFQ rfq;
  final bool canManage;
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

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(projectsRepositoryProvider);
    final rfq = widget.rfq;
    final actions = <AppLifecycleAction>[];

    if (rfq.isEditable && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'Düzenle',
          icon: Icons.edit_outlined,
          onPressed: _busy
              ? null
              : () => context.push(
                  '/projeler/${widget.projectId}/satin-alma/rfqlar/${widget.rfqId}/duzenle',
                ),
        ),
      );
    }
    if (rfq.canIssue && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'Yayınla',
          icon: Icons.send_outlined,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Yayınla',
                    'Bu RFQ yayınlansın mı? Bu, salt DB içi bir durum geçişidir -- hiçbir e-posta/bildirim GÖNDERİLMEZ.',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.issueRFQ(widget.projectId, widget.rfqId),
                  );
                },
        ),
      );
    }
    if (rfq.canClose && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'Kapat (Ödülsüz)',
          icon: Icons.close,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'Kapat',
                    'Bu RFQ ödül vermeden kapatılsın mı?',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.closeRFQ(widget.projectId, widget.rfqId),
                  );
                },
        ),
      );
    }
    if (rfq.canCancel && widget.canManage) {
      actions.add(
        AppLifecycleAction(
          label: 'İptal Et',
          icon: Icons.cancel_outlined,
          onPressed: _busy
              ? null
              : () async {
                  final ok = await _confirm(
                    'İptal Et',
                    'Bu RFQ iptal edilsin mi?',
                  );
                  if (!ok) return;
                  await _run(
                    () => repo.cancelRFQ(widget.projectId, widget.rfqId),
                  );
                },
        ),
      );
    }

    return AppLifecycleActions(actions: actions);
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(text, style: AppTypography.body),
        ],
      ),
    );
  }
}

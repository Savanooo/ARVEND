import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/files/local_documents.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/delete_request.dart' show showNoteDialog;
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import '../inventory_paths.dart';
import 'inventory_common.dart';

/// Fişin ayrıntısı: başlık, satırlar (işaretli miktar, parti/SKT), irsaliye
/// eki; inventory.adjust sahibi gerekçeyle iptal eder (ters fiş açılır).
class InventoryDocumentScreen extends ConsumerWidget {
  const InventoryDocumentScreen({super.key, required this.documentId});

  final String documentId;

  Future<void> _reverse(BuildContext context, WidgetRef ref, InventoryDocument d) async {
    final text = await showNoteDialog(
      context,
      title: 'Fişi İptal Et',
      message: '${d.summary.docNo} geri alınsın mı? Satırların tersini yazan bir iptal fişi açılır; kayıt silinmez.',
      label: 'Gerekçe *',
      confirm: 'İptal Et',
      keyName: 'stok-iptal-gerekce',
    );
    if (text == null || !context.mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('İptal gerekçesi zorunlu.')));
      return;
    }
    try {
      final rev = await ref.read(inventoryRepositoryProvider).reverse(d.id, text);
      invalidateInventory(ref.invalidate);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${d.summary.docNo} iptal edildi.')));
      context.pushReplacement(inventoryDocumentPath(rev.id));
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openAttachment(BuildContext context, WidgetRef ref, InventoryDocument d) async {
    try {
      final bytes = await ref.read(inventoryRepositoryProvider).attachment(d.id);
      final error = await ref.read(documentOpenerProvider)(
        d.attachmentName.isEmpty ? '${d.summary.docNo}-irsaliye' : d.attachmentName,
        bytes,
        mimeType: d.attachmentMime,
      );
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on Exception {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ek açılamadı.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(kInventoryRead)) {
      return const AppPageScaffold(
        title: Text('Stok Fişi'),
        body: Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice('Stok takibini görmek için yetkin yok.')),
      );
    }
    final async = ref.watch(inventoryDocumentProvider(documentId));
    final d = async.valueOrNull;
    final canReverse = user.canAccess(kInventoryAdjust) && d != null && d.canReverse;

    return AppPageScaffold(
      title: Text(d?.summary.docNo ?? 'Stok Fişi'),
      actions: [
        if (canReverse)
          IconButton(
            key: const ValueKey('stok-fis-iptal'),
            tooltip: 'Fişi iptal et',
            icon: const Icon(Icons.undo),
            onPressed: () => _reverse(context, ref, d),
          ),
      ],
      body: AsyncStateView<InventoryDocument>(
        value: async,
        onRetry: () async => ref.invalidate(inventoryDocumentProvider(documentId)),
        data: (context, d) {
          final s = d.summary;
          return ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 96),
            children: [
              AppCard(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(inventoryDocIcon(s.docType), color: AppColors.textMuted),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: Text(s.typeLabel, style: AppTypography.cardTitle)),
                        inventoryDocTypeBadge(s),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    InventoryInfoRow('Tarih', Formatters.date(s.docDate)),
                    InventoryInfoRow(s.docType == kDocTransfer ? 'Kaynak depo' : 'Depo', s.warehouseName),
                    InventoryInfoRow('Hedef depo', s.targetWarehouseName),
                    InventoryInfoRow(s.docType == kDocIssue ? 'Kime' : 'Kimden', s.counterparty),
                    InventoryInfoRow('İrsaliye no', s.referenceNo),
                    InventoryInfoRow('Proje', [d.projectNo, s.projectName].where((v) => v.isNotEmpty).join(' · ')),
                    InventoryInfoRow('Fire nedeni', kWasteReasons[s.reason] ?? ''),
                    InventoryInfoRow('Not', d.note),
                    InventoryInfoRow('Giren', s.createdByName),
                    if (d.reversalOfNo.isNotEmpty) InventoryInfoRow('İptal ettiği', d.reversalOfNo),
                    if (s.isReversed)
                      InventoryInfoRow(
                        'İptal',
                        [d.reversedByDocNo, d.reversedByName, d.reverseReason].where((v) => v.isNotEmpty).join(' · '),
                      ),
                    if (d.hasAttachment)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('stok-fis-ek'),
                          onPressed: () => _openAttachment(context, ref, d),
                          icon: const Icon(Icons.receipt_long_outlined),
                          label: const Text('İrsaliyeyi aç'),
                        ),
                      ),
                    if (s.docType == kDocReceipt || s.docType == kDocIssue || s.docType == kDocTransfer)
                      const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.xs),
                        child: Text('Bu fiş irsaliye yerine geçmez.', style: AppTypography.helper),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppSectionHeader(title: 'Satırlar (${d.lines.length})'),
              if (d.lines.isEmpty)
                const Text('Fark yok (sayılan miktarlar sistemle aynı).', style: AppTypography.helper),
              for (final l in d.lines)
                AppCard(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  onTap: () => context.push(inventoryItemPath(l.itemId)),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.itemName, style: AppTypography.cardTitle),
                            Text(
                              [
                                l.itemCode,
                                l.warehouseName,
                                if (l.lotNo.isNotEmpty) 'Parti ${l.lotNo}',
                                if (l.expiryDate != null) 'SKT ${Formatters.date(l.expiryDate!)}',
                                if (l.unitCost != null && l.unitCost! > 0) '${Formatters.money(l.unitCost!)} / ${l.unit}',
                              ].join(' · '),
                              style: AppTypography.metadata,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${l.quantity > 0 ? '+' : '−'}${formatQty(l.quantity.abs(), l.unit)}',
                        style: AppTypography.body.copyWith(
                          fontWeight: FontWeight.w700,
                          color: l.quantity > 0 ? AppColors.success : AppColors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

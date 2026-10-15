import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import '../inventory_paths.dart';
import 'inventory_common.dart';

/// Stok hareketleri: bütün fişler, en yeni önce; türe göre süzülür.
class InventoryDocumentsScreen extends ConsumerStatefulWidget {
  const InventoryDocumentsScreen({super.key});

  @override
  ConsumerState<InventoryDocumentsScreen> createState() => _InventoryDocumentsScreenState();
}

class _InventoryDocumentsScreenState extends ConsumerState<InventoryDocumentsScreen> {
  String _type = '';

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(kInventoryRead)) {
      return const AppPageScaffold(
        title: Text('Stok Hareketleri'),
        body: Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice('Stok takibini görmek için yetkin yok.')),
      );
    }
    final async = ref.watch(inventoryDocumentsProvider(_type));

    Future<void> refresh() async {
      ref.invalidate(inventoryDocumentsProvider(_type));
      try {
        await ref.read(inventoryDocumentsProvider(_type).future);
      } catch (_) {}
    }

    return AppPageScaffold(
      title: const Text('Stok Hareketleri'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                AppFilterChipData(label: 'Tümü', selected: _type.isEmpty, onTap: () => setState(() => _type = '')),
                for (final e in kInventoryDocLabels.entries)
                  AppFilterChipData(label: e.value, selected: _type == e.key, onTap: () => setState(() => _type = e.key)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: AsyncStateView<List<InventoryDocumentSummary>>(
                value: async,
                onRetry: refresh,
                data: (context, docs) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 96),
                  children: [
                    if (docs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.xl),
                        child: EmptyStateView(message: 'Henüz stok hareketi yok.', icon: Icons.history),
                      )
                    else
                      for (final d in docs)
                        InventoryDocumentRow(
                          key: ValueKey('stok-fis-${d.id}'),
                          doc: d,
                          onTap: () => context.push(inventoryDocumentPath(d.id)),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fiş satırı (hareket listesi ve malzeme sayfası).
class InventoryDocumentRow extends StatelessWidget {
  const InventoryDocumentRow({super.key, required this.doc, required this.onTap});

  final InventoryDocumentSummary doc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final where = d.docType == kDocTransfer || (d.docType == kDocReversal && d.targetWarehouseName.isNotEmpty)
        ? '${d.warehouseName} → ${d.targetWarehouseName}'
        : d.warehouseName;
    final details = [
      Formatters.date(d.docDate),
      where,
      if (d.counterparty.isNotEmpty) d.counterparty,
      if (d.projectName.isNotEmpty) d.projectName,
      if (d.reason.isNotEmpty) kWasteReasons[d.reason] ?? d.reason,
    ].join(' · ');
    return Opacity(
      opacity: d.isReversed ? 0.6 : 1,
      child: AppCard(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(inventoryDocIcon(d.docType), color: AppColors.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.itemsLabel.isEmpty ? d.docNo : d.itemsLabel,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                  Text(details, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.metadata),
                  Text(d.docNo, style: AppTypography.helper),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            inventoryDocTypeBadge(d),
          ],
        ),
      ),
    );
  }
}

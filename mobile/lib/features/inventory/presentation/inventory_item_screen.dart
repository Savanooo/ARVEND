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
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import '../inventory_paths.dart';
import 'inventory_common.dart';
import 'inventory_documents_screen.dart' show InventoryDocumentRow;
import 'inventory_item_form_sheet.dart';

/// Malzemenin sayfası: kart bilgisi, depo ve partilere göre miktar (SKT
/// rozetiyle), son hareketler; buradan giriş/çıkış açılır.
class InventoryItemScreen extends ConsumerWidget {
  const InventoryItemScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(kInventoryRead)) {
      return const AppPageScaffold(
        title: Text('Malzeme'),
        body: Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice('Stok takibini görmek için yetkin yok.')),
      );
    }
    final async = ref.watch(inventoryItemProvider(itemId));
    final detail = async.valueOrNull;
    final canManage = user.canAccess(kInventoryManage);

    Future<void> refresh() async {
      ref.invalidate(inventoryItemProvider(itemId));
      try {
        await ref.read(inventoryItemProvider(itemId).future);
      } catch (_) {}
    }

    Future<void> open(String type) async {
      await context.push(inventoryDocumentFormPath(type, itemId: itemId));
      invalidateInventory(ref.invalidate);
    }

    return AppPageScaffold(
      title: Text(detail?.item.name ?? 'Malzeme'),
      actions: [
        if (detail != null && canManage)
          IconButton(
            key: const ValueKey('stok-kart-duzenle'),
            tooltip: 'Kartı düzenle',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final saved = await showInventoryItemFormSheet(context, existing: detail.item);
              if (saved != null) await refresh();
            },
          ),
      ],
      body: RefreshIndicator(
        onRefresh: refresh,
        child: AsyncStateView<InventoryItemDetail>(
          value: async,
          onRetry: refresh,
          data: (context, d) {
            final it = d.item;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 96),
              children: [
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              formatQty(it.quantity, it.unit),
                              key: const ValueKey('stok-kart-toplam'),
                              style: AppTypography.pageTitle,
                            ),
                          ),
                          if (!it.isActive) const StatusBadge(label: 'Arşivde', tone: StatusTone.muted),
                          if (it.belowMin) const StatusBadge(label: 'Azalan', tone: StatusTone.warning),
                        ],
                      ),
                      const Text('Bütün depolarda', style: AppTypography.helper),
                      const SizedBox(height: AppSpacing.sm),
                      InventoryInfoRow('Kod', it.code),
                      InventoryInfoRow('Barkod', it.barcode),
                      InventoryInfoRow('Kategori', it.category),
                      InventoryInfoRow('Minimum stok', it.minStock == null ? '' : formatQty(it.minStock!, it.unit)),
                      InventoryInfoRow(
                        'SKT takibi',
                        it.trackExpiry
                            ? [
                                it.blocksExpired ? 'Geçince engelle' : 'Geçince uyar',
                                if (it.shelfLifeMonths != null) 'raf ömrü ${it.shelfLifeMonths} ay',
                                '${it.expiryAlertDays} gün önce uyar',
                              ].join(' · ')
                            : 'Yok',
                      ),
                      if (d.canSeeValues && it.avgUnitCost != null) ...[
                        InventoryInfoRow('Ortalama maliyet', Formatters.money(it.avgUnitCost!)),
                        InventoryInfoRow('Stok değeri', Formatters.money(it.stockValue ?? 0)),
                      ],
                      InventoryInfoRow('Not', it.notes),
                    ],
                  ),
                ),
                if (canManage && it.isActive) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('stok-kart-giris'),
                          onPressed: () => open(kDocReceipt),
                          icon: const Icon(Icons.move_to_inbox_outlined),
                          label: const Text('Giriş'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('stok-kart-cikis'),
                          onPressed: it.quantity > 0 ? () => open(kDocIssue) : null,
                          icon: const Icon(Icons.outbox_outlined),
                          label: const Text('Çıkış'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                const AppSectionHeader(title: 'Depolar ve Partiler'),
                if (d.balances.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Text('Stokta yok.', style: AppTypography.helper),
                  )
                else
                  for (final b in d.balances)
                    AppCard(
                      key: ValueKey('stok-bakiye-${b.warehouseId}-${b.lotId ?? ''}'),
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Row(
                        children: [
                          const Icon(Icons.warehouse_outlined, color: AppColors.textMuted, size: 20),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(b.warehouseName, style: AppTypography.cardTitle),
                                if (b.lotNo.isNotEmpty) Text('Parti ${b.lotNo}', style: AppTypography.helper),
                                if (b.expiryDate != null) ...[
                                  const SizedBox(height: 2),
                                  expiryBadge(b.expiryDate, it.expiryAlertDays),
                                ],
                              ],
                            ),
                          ),
                          Text(formatQty(b.quantity, it.unit), style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                const SizedBox(height: AppSpacing.lg),
                const AppSectionHeader(title: 'Son Hareketler'),
                if (d.documents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Text('Henüz hareket yok.', style: AppTypography.helper),
                  )
                else
                  for (final doc in d.documents)
                    InventoryDocumentRow(
                      key: ValueKey('stok-kart-fis-${doc.id}'),
                      doc: doc,
                      onTap: () => context.push(inventoryDocumentPath(doc.id)),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

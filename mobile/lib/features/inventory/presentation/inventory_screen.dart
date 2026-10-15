import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../auth/domain/user.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import '../inventory_paths.dart';
import 'barcode_scanner.dart';
import 'inventory_common.dart';
import 'inventory_item_form_sheet.dart';

enum _Filter { all, expiry, low, archived }

/// "Stok Takibi" (Diğer, backend migration 0072): malzemelerin depolardaki
/// miktarı, SKT'si geçen/yaklaşan ve minimum stoğun altına düşenler.
/// "İşlem" giriş, çıkış, aktarım (inventory.manage), fire ve sayım
/// (inventory.adjust) fişlerini açar.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _warehouseId = '';
  String _query = '';
  _Filter _filter = _Filter.all;

  Future<void> _refresh() async {
    invalidateInventory(ref.invalidate);
    try {
      await ref.read(inventoryItemsProvider(_warehouseId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  Future<void> _openActions(User? user) async {
    final canManage = user.canAccess(kInventoryManage);
    final canAdjust = user.canAccess(kInventoryAdjust);
    final picked = await showAppSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text('Stok İşlemi', style: AppTypography.sectionTitle),
            ),
            if (canManage) ...[
              _action(context, kDocReceipt, 'Giriş', 'Depoya gelen malzeme (irsaliye)'),
              _action(context, kDocIssue, 'Çıkış', 'Depodan verilen malzeme'),
              _action(context, kDocTransfer, 'Aktarım', 'Depodan depoya'),
            ],
            if (canAdjust) ...[
              _action(context, kDocWaste, 'Fire', 'Hasar, SKT geçti, kayıp'),
              _action(context, kDocCount, 'Sayım', 'Sayılan miktarı gir, fark düzeltilsin'),
            ],
            if (canManage)
              ListTile(
                key: const ValueKey('stok-islem-yeni-malzeme'),
                leading: const Icon(Icons.add_box_outlined),
                title: const Text('Yeni Malzeme'),
                subtitle: const Text('Malzeme kartı aç'),
                onTap: () => Navigator.of(context).pop('item'),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'item') {
      final created = await showInventoryItemFormSheet(context);
      if (created != null && mounted) {
        invalidateInventory(ref.invalidate);
        context.push(inventoryItemPath(created.id));
      }
      return;
    }
    await context.push(inventoryDocumentFormPath(picked, warehouseId: _warehouseId));
    if (mounted) invalidateInventory(ref.invalidate);
  }

  /// Barkodu okutur; karta gider. Kart yoksa (yetkiliyse) o barkodla yeni
  /// kart açtırır.
  Future<void> _scanAndOpen(User? user) async {
    final code = await ref.read(barcodeScannerProvider)(context);
    if (code == null || !mounted) return;
    try {
      final item = await ref.read(inventoryRepositoryProvider).itemByBarcode(code);
      if (mounted) context.push(inventoryItemPath(item.id));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.kind != ApiErrorKind.notFound) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$code barkodlu malzeme yok.'),
        action: user.canAccess(kInventoryManage)
            ? SnackBarAction(
                label: 'Kart aç',
                onPressed: () async {
                  final created = await showInventoryItemFormSheet(context, initialBarcode: code);
                  if (created != null && mounted) context.push(inventoryItemPath(created.id));
                },
              )
            : null,
      ));
    }
  }

  Widget _action(BuildContext context, String type, String title, String subtitle) => ListTile(
        key: ValueKey('stok-islem-$type'),
        leading: Icon(inventoryDocIcon(type)),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: () => Navigator.of(context).pop(type),
      );

  @override
  Widget build(BuildContext context) {
    const title = Text('Stok Takibi');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (auth.isLoading && user == null) return const AppPageScaffold(title: title, body: LoadingState());
    if (!user.canAccess(kInventoryRead)) {
      return const AppPageScaffold(
        title: title,
        body: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: ReadOnlyNotice('Stok takibini görmek için yetkin yok.'),
        ),
      );
    }
    final canAct = user.canAccess(kInventoryManage) || user.canAccess(kInventoryAdjust);
    final async = ref.watch(inventoryItemsProvider(_warehouseId));
    final summary = ref.watch(inventorySummaryProvider).valueOrNull;
    final q = _query.toLowerCase();

    return AppPageScaffold(
      title: title,
      actions: [
        IconButton(
          key: const ValueKey('stok-barkod'),
          tooltip: 'Barkod okut',
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () => _scanAndOpen(user),
        ),
        IconButton(
          key: const ValueKey('stok-hareketler'),
          tooltip: 'Hareketler',
          icon: const Icon(Icons.history),
          onPressed: () => context.push(inventoryDocumentsPath),
        ),
        IconButton(
          key: const ValueKey('stok-depolar'),
          tooltip: 'Depolar',
          icon: const Icon(Icons.warehouse_outlined),
          onPressed: () => context.push(inventoryWarehousesPath),
        ),
      ],
      floatingActionButton: canAct
          ? FloatingActionButton.extended(
              key: const ValueKey('stok-islem'),
              onPressed: () => _openActions(user),
              icon: const Icon(Icons.add),
              label: const Text('İşlem'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 96),
          children: [
            if (summary != null) ...[
              _SummaryStrip(
                summary: summary,
                onExpiry: () => setState(() => _filter = _Filter.expiry),
                onLow: () => setState(() => _filter = _Filter.low),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            WarehouseDropdown(
              value: _warehouseId,
              includeAll: true,
              onChanged: (v) => setState(() => _warehouseId = v ?? ''),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('stok-ara'),
              decoration: const InputDecoration(
                hintText: 'Ad, kod, kategori ya da barkod',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppFilterBar(
              chips: [
                AppFilterChipData(label: 'Tümü', selected: _filter == _Filter.all, onTap: () => setState(() => _filter = _Filter.all)),
                AppFilterChipData(label: 'SKT', selected: _filter == _Filter.expiry, onTap: () => setState(() => _filter = _Filter.expiry)),
                AppFilterChipData(label: 'Azalan', selected: _filter == _Filter.low, onTap: () => setState(() => _filter = _Filter.low)),
                AppFilterChipData(label: 'Arşiv', selected: _filter == _Filter.archived, onTap: () => setState(() => _filter = _Filter.archived)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            AsyncStateView<InventoryItemsPage>(
              value: async,
              onRetry: _refresh,
              data: (context, page) {
                final items = page.items.where((i) {
                  final matches = q.isEmpty || '${i.name} ${i.code} ${i.category} ${i.barcode}'.toLowerCase().contains(q);
                  if (!matches) return false;
                  return switch (_filter) {
                    _Filter.all => i.isActive,
                    _Filter.expiry => i.isActive && (i.expiredQuantity > 0 || i.expiringQuantity > 0),
                    _Filter.low => i.isActive && i.belowMin,
                    _Filter.archived => !i.isActive,
                  };
                }).toList();
                if (items.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xl),
                    child: EmptyStateView(
                      message: page.items.isEmpty
                          ? 'Henüz malzeme yok. "İşlem > Yeni Malzeme" ile kart aç, sonra giriş yap.'
                          : 'Bu filtreye uyan malzeme yok.',
                      icon: Icons.inventory_2_outlined,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final it in items)
                      _ItemRow(
                        key: ValueKey('stok-malzeme-${it.id}'),
                        item: it,
                        showValue: page.canSeeValues,
                        onTap: () => context.push(inventoryItemPath(it.id)),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary, required this.onExpiry, required this.onLow});

  final InventorySummary summary;
  final VoidCallback onExpiry;
  final VoidCallback onLow;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final tiles = <Widget>[
      if (s.expiredLotCount > 0)
        _tile('stok-ozet-skt-gecti', Icons.error_outline, AppColors.danger, '${s.expiredLotCount} parti', 'SKT geçti', onExpiry),
      if (s.expiringLotCount > 0)
        _tile('stok-ozet-skt-yakin', Icons.schedule, AppColors.warning, '${s.expiringLotCount} parti', 'SKT yaklaşıyor', onExpiry),
      if (s.belowMinCount > 0)
        _tile('stok-ozet-azalan', Icons.trending_down, AppColors.warning, '${s.belowMinCount} malzeme', 'Azalan stok', onLow),
      if (s.stockValue != null)
        _tile('stok-ozet-deger', Icons.account_balance_wallet_outlined, AppColors.gold, Formatters.money(s.stockValue!),
            'Stok değeri', null),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: tiles);
  }

  Widget _tile(String key, IconData icon, Color color, String value, String label, VoidCallback? onTap) => AppCard(
        key: ValueKey(key),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: AppSpacing.xs),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700, color: color)),
                Text(label, style: AppTypography.helper),
              ],
            ),
          ],
        ),
      );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({super.key, required this.item, required this.showValue, required this.onTap});

  final InventoryItem item;
  final bool showValue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final badges = <Widget>[
      if (it.expiredQuantity > 0)
        StatusBadge(label: 'SKT geçti: ${formatQty(it.expiredQuantity, it.unit)}', tone: StatusTone.danger)
      else if (it.expiringQuantity > 0)
        expiryBadge(it.nearestExpiry, it.expiryAlertDays),
      if (it.belowMin) const StatusBadge(label: 'Azalan', tone: StatusTone.warning),
    ];
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          const Icon(Icons.inventory_2_outlined, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                Text(
                  [it.code, if (it.category.isNotEmpty) it.category].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.metadata,
                ),
                if (badges.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: badges),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatQty(it.quantity, it.unit),
                key: ValueKey('stok-miktar-${it.id}'),
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
              ),
              if (showValue && it.stockValue != null && it.stockValue! > 0)
                Text(Formatters.money(it.stockValue!), style: AppTypography.helper),
            ],
          ),
        ],
      ),
    );
  }
}

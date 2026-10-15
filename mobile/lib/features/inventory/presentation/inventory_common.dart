import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../projects/ops_team/domain/ops_dates.dart' show formatDay, istanbulToday, parseDay;
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import 'barcode_scanner.dart';

/// Bugün (İstanbul), YYYY-AA-GG.
String inventoryToday() => formatDay(istanbulToday())!;

enum ExpiryState { none, ok, soon, expired }

/// SKT durumu: geçti / [alertDays] gün içinde dolacak / uygun.
ExpiryState expiryStateOf(String? expiry, int alertDays) {
  final d = parseDay(expiry);
  if (d == null) return ExpiryState.none;
  final today = istanbulToday();
  if (d.isBefore(today)) return ExpiryState.expired;
  if (!d.isAfter(today.add(Duration(days: alertDays)))) return ExpiryState.soon;
  return ExpiryState.ok;
}

/// "SKT 12.01.2027" rozeti, duruma göre renkli.
Widget expiryBadge(String? expiry, int alertDays) {
  final state = expiryStateOf(expiry, alertDays);
  if (state == ExpiryState.none) return const SizedBox.shrink();
  final label = switch (state) {
    ExpiryState.expired => 'SKT geçti · ${Formatters.date(expiry!)}',
    _ => 'SKT ${Formatters.date(expiry!)}',
  };
  final tone = switch (state) {
    ExpiryState.expired => StatusTone.danger,
    ExpiryState.soon => StatusTone.warning,
    _ => StatusTone.muted,
  };
  return StatusBadge(label: label, tone: tone);
}

Widget inventoryDocTypeBadge(InventoryDocumentSummary d) {
  if (d.isReversed) return const StatusBadge(label: 'İptal edildi', tone: StatusTone.danger);
  final tone = switch (d.docType) {
    kDocReceipt => StatusTone.success,
    kDocIssue => StatusTone.info,
    kDocTransfer => StatusTone.gold,
    kDocWaste => StatusTone.danger,
    kDocReversal => StatusTone.muted,
    _ => StatusTone.muted,
  };
  return StatusBadge(label: d.typeLabel, tone: tone);
}

IconData inventoryDocIcon(String docType) => switch (docType) {
      kDocReceipt => Icons.move_to_inbox_outlined,
      kDocIssue => Icons.outbox_outlined,
      kDocTransfer => Icons.swap_horiz,
      kDocWaste => Icons.delete_sweep_outlined,
      kDocCount => Icons.fact_check_outlined,
      _ => Icons.undo,
    };

/// Kullanıcı sayı girişi: "12,5" / "12.5" / "1.250,5".
double? parseQtyInput(String raw) {
  var s = raw.trim().replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (s.contains(',')) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  }
  return double.tryParse(s);
}

/// Sayıyı alana yazmak için ("12,5").
String qtyInputText(double? v) => v == null ? '' : formatQty(v);

/// Depo seçici (açılır liste). [includeAll] "Bütün depolar" seçeneği ekler
/// (değer '').
class WarehouseDropdown extends ConsumerWidget {
  const WarehouseDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Depo',
    this.includeAll = false,
    this.exclude,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final bool includeAll;
  final String? exclude;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(inventoryWarehousesProvider);
    final list = (async.valueOrNull ?? const <InventoryWarehouse>[])
        .where((w) => w.isActive && w.id != exclude)
        .toList();
    final items = [
      if (includeAll) const DropdownMenuItem(value: '', child: Text('Bütün depolar')),
      for (final w in list) DropdownMenuItem(value: w.id, child: Text(w.name, overflow: TextOverflow.ellipsis)),
    ];
    final current = items.any((i) => i.value == value) ? value : null;
    // initialValue yalnızca ilk çizimde okunur: liste yüklenince ya da
    // seçim dışarıdan değişince alan yeniden kurulsun.
    return DropdownButtonFormField<String>(
      key: ValueKey('stok-depo-$label-$current-${items.length}'),
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: items,
      onChanged: onChanged,
    );
  }
}

/// Malzeme seçici: arama, depodaki miktar ve SKT işareti. Seçilen kart döner.
Future<InventoryItem?> showInventoryItemPicker(BuildContext context, {String warehouseId = ''}) {
  return showAppSheet<InventoryItem>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ItemPickerSheet(warehouseId: warehouseId),
  );
}

class _ItemPickerSheet extends ConsumerStatefulWidget {
  const _ItemPickerSheet({required this.warehouseId});

  final String warehouseId;

  @override
  ConsumerState<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends ConsumerState<_ItemPickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Okunan barkod bir karta aitse doğrudan seçer; değilse aramaya yazar.
  Future<void> _scan() async {
    final code = await ref.read(barcodeScannerProvider)(context);
    if (code == null || !mounted) return;
    final page = ref.read(inventoryItemsProvider(widget.warehouseId)).valueOrNull;
    final match = page?.items.where((i) => i.isActive && i.barcode == code).firstOrNull;
    if (match != null) {
      Navigator.of(context).pop(match);
      return;
    }
    setState(() {
      _search.text = code;
      _query = code;
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(inventoryItemsProvider(widget.warehouseId));
    final q = _query.toLowerCase();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Malzeme Seç', style: AppTypography.sectionTitle),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('stok-malzeme-ara'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Ad, kod ya da barkod',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: IconButton(
                  key: const ValueKey('stok-malzeme-okut'),
                  tooltip: 'Barkod okut',
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _scan,
                ),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: AsyncStateView<InventoryItemsPage>(
                value: async,
                onRetry: () async => ref.invalidate(inventoryItemsProvider(widget.warehouseId)),
                data: (context, page) {
                  final items = page.items
                      .where((i) => i.isActive)
                      .where((i) => q.isEmpty || '${i.name} ${i.code} ${i.barcode}'.toLowerCase().contains(q))
                      .toList();
                  if (items.isEmpty) {
                    return const EmptyStateView(message: 'Malzeme bulunamadı. Önce malzeme kartını açın.');
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final it = items[i];
                      return ListTile(
                        key: ValueKey('stok-secenek-${it.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [it.code, if (it.trackExpiry) 'SKT takipli'].join(' · '),
                          style: AppTypography.helper,
                        ),
                        trailing: Text(
                          formatQty(it.quantity, it.unit),
                          style: AppTypography.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: it.quantity > 0 ? AppColors.textPrimary : AppColors.textMuted,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(it),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bilgi satırı: etiket solda, değer sağda.
class InventoryInfoRow extends StatelessWidget {
  const InventoryInfoRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: AppTypography.helper)),
          Expanded(child: Text(value, style: AppTypography.body)),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';

/// Depolar: liste; inventory.adjust sahibi açar, düzenler, arşivler (stoğu
/// olan depo arşivlenemez).
class InventoryWarehousesScreen extends ConsumerWidget {
  const InventoryWarehousesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(kInventoryRead)) {
      return const AppPageScaffold(
        title: Text('Depolar'),
        body: Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice('Stok takibini görmek için yetkin yok.')),
      );
    }
    final canAdjust = user.canAccess(kInventoryAdjust);
    final async = ref.watch(inventoryWarehousesProvider);

    Future<void> edit([InventoryWarehouse? existing]) async {
      final saved = await showAppSheet<InventoryWarehouse>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _WarehouseFormSheet(existing: existing),
      );
      if (saved != null) invalidateInventory(ref.invalidate);
    }

    return AppPageScaffold(
      title: const Text('Depolar'),
      floatingActionButton: canAdjust
          ? FloatingActionButton.extended(
              key: const ValueKey('stok-depo-ekle'),
              onPressed: edit,
              icon: const Icon(Icons.add),
              label: const Text('Yeni Depo'),
            )
          : null,
      body: AsyncStateView<List<InventoryWarehouse>>(
        value: async,
        onRetry: () async => ref.invalidate(inventoryWarehousesProvider),
        data: (context, list) => ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 96),
          children: [
            for (final w in list)
              AppCard(
                key: ValueKey('stok-depo-${w.id}'),
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                padding: const EdgeInsets.all(AppSpacing.md),
                onTap: canAdjust ? () => edit(w) : null,
                child: Row(
                  children: [
                    Icon(Icons.warehouse_outlined, color: w.isActive ? AppColors.gold : AppColors.textMuted),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(w.name, style: AppTypography.cardTitle),
                          Text(
                            [if (w.address.isNotEmpty) w.address, '${w.itemCount} malzeme'].join(' · '),
                            style: AppTypography.metadata,
                          ),
                        ],
                      ),
                    ),
                    if (!w.isActive) const StatusBadge(label: 'Arşivde', tone: StatusTone.muted),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WarehouseFormSheet extends ConsumerStatefulWidget {
  const _WarehouseFormSheet({this.existing});

  final InventoryWarehouse? existing;

  @override
  ConsumerState<_WarehouseFormSheet> createState() => _WarehouseFormSheetState();
}

class _WarehouseFormSheetState extends ConsumerState<_WarehouseFormSheet> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _address = TextEditingController(text: widget.existing?.address ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late bool _active = widget.existing?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Depo adı zorunlu.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref.read(inventoryRepositoryProvider).saveWarehouse(
            id: widget.existing?.id,
            name: _name.text.trim(),
            address: _address.text.trim(),
            notes: _notes.text.trim(),
            isActive: widget.existing == null ? null : _active,
          );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'Yeni Depo' : 'Depo', style: AppTypography.sectionTitle),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('stok-depo-ad'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Depo adı *'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _address, decoration: const InputDecoration(labelText: 'Adres')),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Not')),
            if (widget.existing != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aktif'),
                subtitle: const Text('Stoğu olan depo arşivlenemez'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(key: const ValueKey('stok-depo-kaydet'), label: 'Kaydet', loading: _saving, onPressed: _save),
          ],
        ),
      ),
    );
  }
}

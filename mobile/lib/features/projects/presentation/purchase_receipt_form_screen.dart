import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../inventory/domain/inventory.dart';
import '../budget/domain/budget.dart' show formatTrDecimalInput;
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../finance_plan/domain/finance_dates.dart' show parseAmountInput;

/// Miktarı Türkçe ondalıkla, gereksiz sıfırsız yazar ("40", "12,5").
String formatReceiptQty(double v) => formatTrDecimalInput(v);

/// Siparişten teslim alma (backend migration 0074): bir irsaliye girilir --
/// tarih, irsaliye no, teslim yeri (şantiye ya da depo) ve kalem başına
/// kabul / red miktarı. Kabul alanı bekleyen miktarla dolu açılır. Kabul tavanı = sipariş - önceki kabuller (sunucu da
/// zorlar). Teslim maliyet yazmaz; malın maliyeti siparişe bağlanan
/// masraftan (fatura) gelir. Kaydedilirse true döner.
class PurchaseReceiptFormScreen extends ConsumerStatefulWidget {
  const PurchaseReceiptFormScreen({super.key, required this.projectId, required this.poId});
  final String projectId;
  final String poId;

  @override
  ConsumerState<PurchaseReceiptFormScreen> createState() => _PurchaseReceiptFormScreenState();
}

class _PurchaseReceiptFormScreenState extends ConsumerState<PurchaseReceiptFormScreen> {
  @override
  Widget build(BuildContext context) {
    final args = (projectId: widget.projectId, poId: widget.poId);
    final detail = ref.watch(purchaseOrderDetailProvider(args));
    return AppPageScaffold(
      title: const Text('Teslim Al'),
      body: AsyncStateView(
        value: detail,
        onRetry: () async => ref.invalidate(purchaseOrderDetailProvider(args)),
        data: (context, d) => _ReceiptForm(projectId: widget.projectId, detail: d),
      ),
    );
  }
}

/// Kabul alanı BEKLEYEN miktarla dolu açılır (hepsi geldiyse tek dokunuş);
/// reddedilenin yerine gelen varsa kullanıcı tavana (sipariş - kabul) kadar
/// artırabilir.
String _prefill(PurchaseOrderItem item) {
  final w = item.waitingQuantity ?? item.maxAcceptable;
  return w > 0 ? formatReceiptQty(w) : '';
}

class _Line {
  _Line(this.item)
      : accepted = TextEditingController(text: _prefill(item)),
        rejected = TextEditingController(),
        reason = TextEditingController();

  final PurchaseOrderItem item;
  final TextEditingController accepted;
  final TextEditingController rejected;
  final TextEditingController reason;

  double get acceptedValue => parseAmountInput(accepted.text) ?? 0;
  double get rejectedValue => parseAmountInput(rejected.text) ?? 0;

  void dispose() {
    accepted.dispose();
    rejected.dispose();
    reason.dispose();
  }
}

class _ReceiptForm extends ConsumerStatefulWidget {
  const _ReceiptForm({required this.projectId, required this.detail});
  final String projectId;
  final PurchaseOrderDetail detail;

  @override
  ConsumerState<_ReceiptForm> createState() => _ReceiptFormState();
}

class _ReceiptFormState extends ConsumerState<_ReceiptForm> {
  final _formKey = GlobalKey<FormState>();
  final _deliveryNote = TextEditingController();
  final _notes = TextEditingController();
  late final List<_Line> _lines = [for (final i in widget.detail.items) _Line(i)];
  DateTime _date = clock.now();
  String _destination = 'site';
  String? _warehouseId;
  bool _busy = false;
  String? _error;
  late final _idempotencyKey = 'po-receipt-${widget.detail.order.id}-${clock.now().microsecondsSinceEpoch}';

  @override
  void dispose() {
    _deliveryNote.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  String get _isoDate =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final items = [
      for (final l in _lines)
        if (l.acceptedValue > 0 || l.rejectedValue > 0)
          PurchaseReceiptItem(
            purchaseOrderItemId: l.item.id,
            acceptedQuantity: l.acceptedValue,
            rejectedQuantity: l.rejectedValue,
            rejectionReason: l.rejectedValue > 0 ? l.reason.text.trim() : '',
          ),
    ];
    if (items.isEmpty) {
      setState(() => _error = 'En az bir kalemin kabul ya da red miktarını girin.');
      return;
    }
    if (_destination == 'warehouse' && _warehouseId == null) {
      setState(() => _error = 'Depoyu seçin.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(projectsRepositoryProvider).createPurchaseReceipt(
            widget.projectId,
            widget.detail.order.id,
            receivedDate: _isoDate,
            deliveryNoteNo: _deliveryNote.text.trim(),
            destination: _destination,
            warehouseId: _destination == 'warehouse' ? _warehouseId : null,
            notes: _notes.text.trim(),
            idempotencyKey: _idempotencyKey,
            items: items,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(const SnackBar(content: Text('Teslim kaydedildi.')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Teslim almak için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.detail.order;
    final user = ref.watch(authControllerProvider).valueOrNull;
    // Depo listesi Stok Takibi izni ister; yoksa yalnızca şantiye.
    final canListWarehouses = user == null || user.permissions.isEmpty || user.hasPermission('inventory.read');
    return UnsavedChangesScope(
      busy: _busy,
      child: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
          ),
          children: [
            Text('${order.poNo} · ${order.supplierName ?? order.supplierCode ?? ''}', style: AppTypography.cardTitle),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'Teslim maliyet yazmaz: malın maliyeti siparişe bağlanan faturadan (masraf) gelir.',
              style: AppTypography.helper,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppFormSection(
              title: 'İrsaliye',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Teslim tarihi'),
                  subtitle: Text(Formatters.date(_isoDate)),
                  trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
                TextFormField(
                  key: const ValueKey('receipt-delivery-note'),
                  controller: _deliveryNote,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'İrsaliye no (opsiyonel)', counterText: ''),
                ),
                SegmentedButton<String>(
                  key: const ValueKey('receipt-destination'),
                  segments: [
                    const ButtonSegment(value: 'site', label: Text('Şantiye'), icon: Icon(Icons.construction)),
                    ButtonSegment(
                      value: 'warehouse',
                      label: const Text('Depo'),
                      icon: const Icon(Icons.warehouse_outlined),
                      enabled: canListWarehouses,
                    ),
                  ],
                  selected: {_destination},
                  onSelectionChanged: _busy ? null : (s) => setState(() => _destination = s.first),
                ),
                if (_destination == 'warehouse')
                  _WarehousePicker(
                    value: _warehouseId,
                    onChanged: (v) => setState(() => _warehouseId = v),
                  ),
                if (_destination == 'warehouse')
                  const Text(
                    'Stok Takibi\'ne giriş fişi otomatik kesilmez; depoya alınan malzemeyi ayrıca masraf girmeyin.',
                    style: AppTypography.helper,
                  ),
              ],
            ),
            AppFormSection(
              title: 'Kalemler',
              subtitle: 'Gelip sağlam olanı kabul, hasarlı ya da yanlış geleni red olarak girin.',
              children: [for (final l in _lines) _LineCard(line: l, enabled: !_busy, onChanged: () => setState(() {}))],
            ),
            AppFormSection(
              title: 'Not',
              children: [
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Not (opsiyonel)'),
                ),
              ],
            ),
            if (_error != null) ...[
              Text(_error!, style: AppTypography.error),
              const SizedBox(height: AppSpacing.md),
            ],
            PrimaryButton(
              key: const ValueKey('receipt-save'),
              label: 'Teslimi Kaydet',
              loading: _busy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class _WarehousePicker extends ConsumerWidget {
  const _WarehousePicker({required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warehouses = ref.watch(inventoryWarehousesProvider);
    return warehouses.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => const Text('Depolar yüklenemedi.', style: AppTypography.error),
      data: (list) {
        final active = list.where((InventoryWarehouse w) => w.isActive).toList();
        if (active.isEmpty) {
          return const Text('Açık depo yok. Stok Takibi\'nden depo ekleyin.', style: AppTypography.helper);
        }
        return DropdownButtonFormField<String>(
          key: const ValueKey('receipt-warehouse'),
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Depo'),
          items: [for (final w in active) DropdownMenuItem(value: w.id, child: Text(w.name))],
          onChanged: onChanged,
          validator: (v) => v == null ? 'Depoyu seçin' : null,
        );
      },
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line, required this.enabled, required this.onChanged});
  final _Line line;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final it = line.item;
    final unit = it.unit.isEmpty ? '' : ' ${it.unit}';
    final max = it.maxAcceptable;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(it.description, style: AppTypography.cardTitle),
          const SizedBox(height: 2),
          Text(
            'Sipariş ${formatReceiptQty(it.quantity)}$unit · '
            'kabul ${formatReceiptQty(it.acceptedQuantity ?? 0)} · '
            'bekleyen ${formatReceiptQty(it.waitingQuantity ?? it.quantity)}',
            style: AppTypography.metadata,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('receipt-accepted-${it.id}'),
                  controller: line.accepted,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Kabul$unit'),
                  onChanged: (_) => onChanged(),
                  validator: (v) {
                    if ((v ?? '').trim().isEmpty) return null;
                    final q = parseAmountInput(v!);
                    if (q == null || q < 0) return 'Geçerli miktar';
                    // Kuruş yuvarlamasıyla sınırda yanlış ret olmasın.
                    if (q > max + 0.005) return 'En fazla ${formatReceiptQty(max)}';
                    return null;
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: TextFormField(
                  key: ValueKey('receipt-rejected-${it.id}'),
                  controller: line.rejected,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Red$unit'),
                  onChanged: (_) => onChanged(),
                  validator: (v) {
                    if ((v ?? '').trim().isEmpty) return null;
                    final q = parseAmountInput(v!);
                    if (q == null || q < 0) return 'Geçerli miktar';
                    return null;
                  },
                ),
              ),
            ],
          ),
          if (line.rejectedValue > 0)
            TextFormField(
              key: ValueKey('receipt-reason-${it.id}'),
              controller: line.reason,
              enabled: enabled,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Red nedeni', counterText: ''),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Red nedenini yazın' : null,
            ),
        ],
      ),
    );
  }
}

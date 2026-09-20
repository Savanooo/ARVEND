import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../domain/subcontract.dart' show OrgCostCode, Supplier;

class _DraftItem {
  _DraftItem();

  String costCodeId = '';
  String description = '';
  String quantity = '';
  String unit = '';
  String unitPrice = '';

  factory _DraftItem.fromItem(PurchaseOrderItem item) => _DraftItem()
    ..costCodeId = item.costCodeId
    ..description = item.description
    ..quantity = _numStr(item.quantity)
    ..unit = item.unit
    ..unitPrice = _numStr(item.unitPrice);

  static String _numStr(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toString();
  }
}

String? _fmtDate(DateTime? d) {
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// P3 — Satın Alma Siparişi Ekle/Düzenle. Create + Edit AYNI ekran. Backend'de
/// "ödüllü teklifTEN sipariş oluştur" diye AYRI bir uç YOK (bkz. Phase 1) --
/// [prefillSupplierId]/[prefillItems]/[sourceRfqId]/[sourceQuotationId]
/// yalnızca RFQ detay ekranının, ödüllü bir teklifin verilerini bu forma
/// ÖNCEDEN DOLDURMASI için MOBİL-TARAFI bir kolaylıktır -- kalemler HER
/// ZAMAN kullanıcı tarafından gözden geçirilip gönderilir, hiçbir şey
/// otomatik oluşturulmaz. `cost_code_id` HER kalemde ZORUNLUDUR (PR/RFQ'dan
/// FARKLI, bkz. Phase 1: DB NOT NULL).
class PurchaseOrderFormScreen extends ConsumerStatefulWidget {
  const PurchaseOrderFormScreen({
    super.key,
    required this.projectId,
    this.poId,
    this.prefillSupplierId,
    this.sourceRfqId,
    this.sourceQuotationId,
    this.prefillItems = const [],
  });

  final String projectId;
  final String? poId;
  final String? prefillSupplierId;
  final String? sourceRfqId;
  final String? sourceQuotationId;
  final List<PurchaseOrderItem> prefillItems;

  bool get isEdit => poId != null;

  @override
  ConsumerState<PurchaseOrderFormScreen> createState() => _PurchaseOrderFormScreenState();
}

class _PurchaseOrderFormScreenState extends ConsumerState<PurchaseOrderFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _paymentTermsController = TextEditingController();
  final _deliveryAddressController = TextEditingController();
  final _notesController = TextEditingController();
  final _taxRateController = TextEditingController(text: '20');
  final List<_DraftItem> _items = [];
  String? _supplierId;
  DateTime? _issueDate;
  DateTime? _expectedDeliveryDate;
  bool _loading = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting());
    } else {
      _supplierId = widget.prefillSupplierId;
      _issueDate = DateTime.now();
      if (widget.prefillItems.isNotEmpty) {
        _items.addAll(widget.prefillItems.map(_DraftItem.fromItem));
      } else {
        _items.add(_DraftItem());
      }
    }
  }

  Future<void> _loadExisting() async {
    try {
      final detail = await ref.read(projectsRepositoryProvider).purchaseOrderDetail(widget.projectId, widget.poId!);
      if (!mounted) return;
      if (!detail.order.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu sipariş yalnızca taslak durumdayken düzenlenebilir.';
        });
        return;
      }
      final po = detail.order;
      _supplierId = po.supplierId.isEmpty ? null : po.supplierId;
      _issueDate = _parseDate(po.issueDate);
      _expectedDeliveryDate = _parseDate(po.expectedDeliveryDate);
      _paymentTermsController.text = po.paymentTerms;
      _deliveryAddressController.text = po.deliveryAddress;
      _notesController.text = po.notes;
      _taxRateController.text = _DraftItem._numStr(po.taxRate);
      _items
        ..clear()
        ..addAll(detail.items.map(_DraftItem.fromItem));
      if (_items.isEmpty) _items.add(_DraftItem());
      setState(() => _loading = false);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  void dispose() {
    _paymentTermsController.dispose();
    _deliveryAddressController.dispose();
    _notesController.dispose();
    _taxRateController.dispose();
    super.dispose();
  }

  List<PurchaseOrderItem> _buildItems() {
    final out = <PurchaseOrderItem>[];
    for (final i in _items) {
      final qty = double.tryParse(i.quantity.replaceAll(',', '.'));
      final price = double.tryParse(i.unitPrice.replaceAll(',', '.'));
      if (i.costCodeId.isEmpty || i.description.trim().isEmpty || qty == null || qty <= 0 || price == null || price <= 0) {
        continue;
      }
      out.add(PurchaseOrderItem(
        id: '',
        wbsNodeId: null,
        costCodeId: i.costCodeId,
        budgetLineId: null,
        description: i.description.trim(),
        quantity: qty,
        unit: i.unit,
        unitPrice: price,
        lineTotal: 0,
        sortOrder: 0,
      ));
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_supplierId == null || _supplierId!.isEmpty) {
      setState(() => _error = 'Tedarikçi seçin.');
      return;
    }
    final items = _buildItems();
    if (items.isEmpty) {
      setState(() => _error = 'En az bir geçerli kalem girin (maliyet kodu, açıklama, miktar > 0, birim fiyat > 0).');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final taxRate = double.tryParse(_taxRateController.text.replaceAll(',', '.')) ?? 0;
      final PurchaseOrder po;
      if (widget.isEdit) {
        po = await repo.updatePurchaseOrder(
          widget.projectId,
          widget.poId!,
          supplierId: _supplierId!,
          sourceRfqId: widget.sourceRfqId,
          sourceQuotationId: widget.sourceQuotationId,
          issueDate: _fmtDate(_issueDate),
          expectedDeliveryDate: _fmtDate(_expectedDeliveryDate),
          paymentTerms: _paymentTermsController.text.trim(),
          deliveryAddress: _deliveryAddressController.text.trim(),
          notes: _notesController.text.trim(),
          taxRate: taxRate,
          items: items,
        );
      } else {
        po = await repo.createPurchaseOrder(
          widget.projectId,
          supplierId: _supplierId!,
          sourceRfqId: widget.sourceRfqId,
          sourceQuotationId: widget.sourceQuotationId,
          issueDate: _fmtDate(_issueDate),
          expectedDeliveryDate: _fmtDate(_expectedDeliveryDate),
          paymentTerms: _paymentTermsController.text.trim(),
          deliveryAddress: _deliveryAddressController.text.trim(),
          notes: _notesController.text.trim(),
          taxRate: taxRate,
          items: items,
        );
      }
      ref.invalidate(projectPurchaseOrdersProvider(widget.projectId));
      if (widget.isEdit) {
        ref.invalidate(purchaseOrderDetailProvider((projectId: widget.projectId, poId: widget.poId!)));
      }
      if (mounted) context.go('/projeler/${widget.projectId}/satin-alma/siparisler/${po.id}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliersAsync = ref.watch(suppliersProvider);
    final costCodesAsync = ref.watch(orgCostCodesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Siparişi Düzenle' : 'Yeni Satın Alma Siparişi')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : suppliersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _RetryView(error: e, onRetry: () => ref.invalidate(suppliersProvider)),
              data: (suppliers) => costCodesAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _RetryView(error: e, onRetry: () => ref.invalidate(orgCostCodesProvider)),
                data: (costCodes) => _buildForm(context, suppliers, costCodes),
              ),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<Supplier> suppliers, List<OrgCostCode> costCodes) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.sourceRfqId != null || widget.sourceQuotationId != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Ödüllendirilmiş bir tekliften ön dolduruldu -- göndermeden önce gözden geçirin.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ),
          DropdownButtonFormField<String>(
            initialValue: _supplierId,
            decoration: const InputDecoration(labelText: 'Tedarikçi'),
            items: suppliers
                .where((s) => s.isActive || s.id == _supplierId)
                .map((s) => DropdownMenuItem(
                      value: s.id,
                      child: Text(s.code.isNotEmpty ? '${s.code} — ${s.displayName}' : s.displayName,
                          overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _supplierId = v),
            validator: (v) => (v == null || v.isEmpty) ? 'Tedarikçi seçin' : null,
          ),
          const SizedBox(height: 12),
          _DatePickerTile(
            label: 'Sipariş Tarihi (opsiyonel)',
            value: _issueDate,
            onChanged: (d) => setState(() => _issueDate = d),
          ),
          _DatePickerTile(
            label: 'Beklenen Teslimat (opsiyonel)',
            value: _expectedDeliveryDate,
            onChanged: (d) => setState(() => _expectedDeliveryDate = d),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _paymentTermsController,
            decoration: const InputDecoration(labelText: 'Ödeme Koşulları (opsiyonel)'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _deliveryAddressController,
            decoration: const InputDecoration(labelText: 'Teslimat Adresi (opsiyonel)'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _taxRateController,
            decoration: const InputDecoration(labelText: 'KDV Oranı (%)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Kalem Ekle'),
                onPressed: () => setState(() => _items.add(_DraftItem())),
              ),
            ],
          ),
          ..._items.asMap().entries.map((entry) => _ItemRow(
                item: entry.value,
                costCodes: costCodes,
                onChanged: () => setState(() {}),
                onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
              )),
          const SizedBox(height: 12),
          TextFormField(
            controller: _notesController,
            decoration: const InputDecoration(labelText: 'Notlar (opsiyonel)'),
            maxLines: 3,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text(widget.isEdit ? 'Kaydet' : 'Siparişi Oluştur'),
          ),
        ],
      ),
    );
  }
}

class _DatePickerTile extends StatelessWidget {
  const _DatePickerTile({required this.label, required this.value, required this.onChanged});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: value != null
          ? Text('${value!.day.toString().padLeft(2, '0')}.${value!.month.toString().padLeft(2, '0')}.${value!.year}')
          : null,
      trailing: value != null
          ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => onChanged(null))
          : const Icon(Icons.calendar_today_outlined, size: 18),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.costCodes, required this.onChanged, this.onRemove});

  final _DraftItem item;
  final List<OrgCostCode> costCodes;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: item.costCodeId.isEmpty ? null : item.costCodeId,
                    decoration: const InputDecoration(labelText: 'Maliyet Kodu', isDense: true),
                    items: costCodes
                        .where((c) => c.isActive || c.id == item.costCodeId)
                        .map((c) => DropdownMenuItem(
                              value: c.id,
                              child: Text('${c.code} — ${c.name}', overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (v) {
                      item.costCodeId = v ?? '';
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: item.description,
              decoration: const InputDecoration(labelText: 'Açıklama', isDense: true),
              onChanged: (v) {
                item.description = v;
                onChanged();
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: item.quantity,
                    decoration: const InputDecoration(labelText: 'Miktar', isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      item.quantity = v;
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: item.unit,
                    decoration: const InputDecoration(labelText: 'Birim', isDense: true),
                    onChanged: (v) {
                      item.unit = v;
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: item.unitPrice,
                    decoration: const InputDecoration(labelText: 'Birim Fiyat', isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      item.unitPrice = v;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RetryView extends StatelessWidget {
  const _RetryView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException ? (error as ApiException).message : 'Beklenmeyen bir hata oluştu.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
          ],
        ),
      ),
    );
  }
}

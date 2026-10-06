import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../domain/subcontract.dart' show OrgCostCode, Supplier;
import 'form_number_input.dart';

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
    ..quantity = formNumberText(item.quantity)
    ..unit = item.unit
    ..unitPrice = formNumberText(item.unitPrice);

  /// Hiç dokunulmamış satır gönderilmez; YARIM doldurulmuş ya da geçersiz
  /// bir satır ise satırın kendi alanında hata gösterir ve kaydı durdurur
  /// (eskiden sessizce atlanıyordu -- kullanıcı kalemin kaybolduğunu fark
  /// etmezdi).
  bool get isBlank =>
      costCodeId.isEmpty && description.trim().isEmpty && quantity.trim().isEmpty && unitPrice.trim().isEmpty;
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
      _taxRateController.text = formNumberText(po.taxRate);
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

  /// Form doğrulandıktan SONRA çağrılır: boş olmayan her satır geçerlidir.
  List<PurchaseOrderItem> _buildItems() => [
        for (final i in _items)
          if (!i.isBlank)
            PurchaseOrderItem(
              id: '',
              wbsNodeId: null,
              costCodeId: i.costCodeId,
              budgetLineId: null,
              description: i.description.trim(),
              quantity: parseFormNumber(i.quantity)!,
              unit: i.unit,
              unitPrice: parseFormNumber(i.unitPrice)!,
              lineTotal: 0,
              sortOrder: 0,
            ),
      ];

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
      final taxRate = parseFormPercent(_taxRateController.text) ?? 0;
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

    return AppPageScaffold(
      title: Text(widget.isEdit ? 'Siparişi Düzenle' : 'Yeni Satın Alma Siparişi'),
      body: _loading
          ? const LoadingState()
          : AsyncStateView<List<Supplier>>(
              value: suppliersAsync,
              onRetry: () async => ref.invalidate(suppliersProvider),
              data: (context, suppliers) => AsyncStateView<List<OrgCostCode>>(
                value: costCodesAsync,
                onRetry: () async => ref.invalidate(orgCostCodesProvider),
                data: (context, costCodes) => _buildForm(context, suppliers, costCodes),
              ),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<Supplier> suppliers, List<OrgCostCode> costCodes) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (widget.sourceRfqId != null || widget.sourceQuotationId != null) ...[
            Text(
              'Ödüllendirilmiş bir tekliften ön dolduruldu -- göndermeden önce gözden geçirin.',
              style: AppTypography.metadata,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          AppFormSection(
            title: 'Tedarikçi ve Sipariş Bilgileri',
            children: [
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
              _DatePickerTile(
                label: 'Sipariş Tarihi (opsiyonel)',
                value: _issueDate,
                onChanged: (d) => setState(() => _issueDate = d),
              ),
            ],
          ),
          AppFormSection(
            title: 'Ticari Bilgiler',
            children: [
              _DatePickerTile(
                label: 'Beklenen Teslimat (opsiyonel)',
                value: _expectedDeliveryDate,
                onChanged: (d) => setState(() => _expectedDeliveryDate = d),
              ),
              TextFormField(
                controller: _paymentTermsController,
                decoration: const InputDecoration(labelText: 'Ödeme Koşulları (opsiyonel)'),
              ),
              TextFormField(
                controller: _deliveryAddressController,
                decoration: const InputDecoration(labelText: 'Teslimat Adresi (opsiyonel)'),
              ),
              TextFormField(
                controller: _taxRateController,
                decoration: const InputDecoration(labelText: 'KDV Oranı (%)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: formPercentError,
              ),
            ],
          ),
          AppFormSection(
            title: 'Kalemler',
            children: [
              ..._items.asMap().entries.map((entry) => _ItemRow(
                    key: ObjectKey(entry.value),
                    item: entry.value,
                    costCodes: costCodes,
                    onChanged: () => setState(() {}),
                    onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
                  )),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Kalem Ekle'),
                  onPressed: () => setState(() => _items.add(_DraftItem())),
                ),
              ),
            ],
          ),
          AppFormSection(
            title: 'Notlar',
            children: [
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(labelText: 'Notlar (opsiyonel)'),
                maxLines: 3,
              ),
            ],
          ),
          if (_error != null) ...[
            Text(_error!, style: AppTypography.error),
            const SizedBox(height: AppSpacing.md),
          ],
          PrimaryButton(
            label: widget.isEdit ? 'Kaydet' : 'Siparişi Oluştur',
            loading: _submitting,
            onPressed: _submit,
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
  const _ItemRow({super.key, required this.item, required this.costCodes, required this.onChanged, this.onRemove});

  final _DraftItem item;
  final List<OrgCostCode> costCodes;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: item.costCodeId.isEmpty ? null : item.costCodeId,
                  decoration: const InputDecoration(labelText: 'Maliyet Kodu', isDense: true),
                  validator: (v) => item.isBlank || (v != null && v.isNotEmpty) ? null : 'Maliyet kodu seçin',
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
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            initialValue: item.description,
            decoration: const InputDecoration(labelText: 'Açıklama', isDense: true),
            validator: (v) => item.isBlank || (v ?? '').trim().isNotEmpty ? null : 'Açıklama gerekli',
            onChanged: (v) {
              item.description = v;
              onChanged();
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: item.quantity,
                  decoration: const InputDecoration(labelText: 'Miktar', isDense: true, errorMaxLines: 3),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => item.isBlank ? null : formNumberError(v),
                  onChanged: (v) {
                    item.quantity = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
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
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextFormField(
                  initialValue: item.unitPrice,
                  decoration: const InputDecoration(labelText: 'Birim Fiyat', isDense: true, errorMaxLines: 3),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => item.isBlank ? null : formNumberError(v),
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
    );
  }
}

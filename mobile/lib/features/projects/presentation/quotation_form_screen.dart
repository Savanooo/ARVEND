import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../domain/subcontract.dart' show Supplier;

class _DraftItem {
  _DraftItem({required this.rfqItemId, required this.description, required this.unit});

  final String rfqItemId;
  final String description;
  final String unit;
  String quantity = '';
  String unitPrice = '';
  String notes = '';

  static String numStr(double v) {
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

/// P3 — Tedarikçi Teklifi Ekle/Düzenle. Kalemler DİNAMİK bir liste
/// DEĞİLDİR -- RFQ'nun KENDİ kalem listesindeki her satır için bir fiyat
/// girilir (backend `rfq_item_id` bazlı çalışır, bkz. Phase 1). `currency`/
/// `subtotal`/`tax`/`total` bu formda HİÇ YOK -- backend hesaplar, mobil
/// bunları asla göstermeye/göndermeye ÇALIŞMAZ.
class QuotationFormScreen extends ConsumerStatefulWidget {
  const QuotationFormScreen({super.key, required this.projectId, required this.rfqId, this.quotationId});

  final String projectId;
  final String rfqId;
  final String? quotationId;

  bool get isEdit => quotationId != null;

  @override
  ConsumerState<QuotationFormScreen> createState() => _QuotationFormScreenState();
}

class _QuotationFormScreenState extends ConsumerState<QuotationFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _quotationNumberController = TextEditingController();
  final _discountController = TextEditingController(text: '0');
  final _taxRateController = TextEditingController(text: '20');
  final _deliveryDaysController = TextEditingController();
  final _paymentTermsController = TextEditingController();
  final _notesController = TextEditingController();
  final List<_DraftItem> _items = [];
  String? _supplierId;
  String? _supplierLabel;
  DateTime? _quotationDate;
  DateTime? _validUntil;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _quotationDate = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final rfqDetail = await repo.rfqDetail(widget.projectId, widget.rfqId);
      // Award, status'u AYNI atomik UPDATE'te 'closed' yapar -- yani
      // status=='issued' olmak zaten awardedQuotationId==null anlamına
      // gelir (bkz. Phase 1). Bu, backend'deki `requireOpenRFQForQuotation`
      // kapısıyla AYNI koşuldur.
      if (rfqDetail.rfq.status != RFQ.statusIssued) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = widget.isEdit
              ? 'Bu RFQ artık açık değil -- teklif düzenlenemez.'
              : 'Bu RFQ açık değil (yayınlanmış ve ödüllendirilmemiş olmalı) -- yeni teklif eklenemez.';
        });
        return;
      }

      if (widget.isEdit) {
        final detail = await repo.quotationDetail(widget.projectId, widget.rfqId, widget.quotationId!);
        final q = detail.quotation;
        _supplierId = q.supplierId;
        // `GetQuotation` (bare, tek teklif) supplier_name/code TAŞIMAZ (bkz.
        // Phase 1) -- bu yüzden RFQ'nun davetli tedarikçi listesinden
        // eşleştirilir.
        _supplierLabel = q.supplierId;
        for (final s in rfqDetail.suppliers) {
          if (s.supplierId == q.supplierId && s.supplierName.isNotEmpty) {
            _supplierLabel = s.supplierName;
            break;
          }
        }
        _quotationNumberController.text = q.quotationNumber;
        _quotationDate = _parseDate(q.quotationDate);
        _validUntil = _parseDate(q.validUntil);
        _discountController.text = _DraftItem.numStr(q.discount);
        _taxRateController.text = _DraftItem.numStr(q.taxRate);
        _deliveryDaysController.text = q.deliveryDays?.toString() ?? '';
        _paymentTermsController.text = q.paymentTerms;
        _notesController.text = q.notes;
        final existingByRfqItem = {for (final it in detail.items) it.rfqItemId: it};
        for (final rfqItem in rfqDetail.items) {
          final draft = _DraftItem(rfqItemId: rfqItem.id, description: rfqItem.description, unit: rfqItem.unit);
          final existing = existingByRfqItem[rfqItem.id];
          if (existing != null) {
            draft.quantity = _DraftItem.numStr(existing.quantity);
            draft.unitPrice = _DraftItem.numStr(existing.unitPrice);
            draft.notes = existing.notes;
          } else {
            draft.quantity = _DraftItem.numStr(rfqItem.quantity);
          }
          _items.add(draft);
        }
      } else {
        for (final rfqItem in rfqDetail.items) {
          _items.add(_DraftItem(rfqItemId: rfqItem.id, description: rfqItem.description, unit: rfqItem.unit)
            ..quantity = _DraftItem.numStr(rfqItem.quantity));
        }
      }
      if (!mounted) return;
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
    _quotationNumberController.dispose();
    _discountController.dispose();
    _taxRateController.dispose();
    _deliveryDaysController.dispose();
    _paymentTermsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  List<QuotationItem> _buildItems() {
    final out = <QuotationItem>[];
    for (final i in _items) {
      final qty = double.tryParse(i.quantity.replaceAll(',', '.'));
      final price = double.tryParse(i.unitPrice.replaceAll(',', '.'));
      if (qty == null || qty <= 0 || price == null || price <= 0) continue;
      out.add(QuotationItem(id: '', rfqItemId: i.rfqItemId, quantity: qty, unitPrice: price, lineTotal: 0, notes: i.notes));
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!widget.isEdit && (_supplierId == null || _supplierId!.isEmpty)) {
      setState(() => _error = 'Tedarikçi seçin.');
      return;
    }
    final items = _buildItems();
    if (items.isEmpty) {
      setState(() => _error = 'En az bir kalem için miktar ve birim fiyat girin.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final discount = double.tryParse(_discountController.text.replaceAll(',', '.')) ?? 0;
      final taxRate = double.tryParse(_taxRateController.text.replaceAll(',', '.')) ?? 0;
      final deliveryDays = int.tryParse(_deliveryDaysController.text);
      final Quotation q;
      if (widget.isEdit) {
        q = await repo.updateQuotation(
          widget.projectId,
          widget.rfqId,
          widget.quotationId!,
          quotationNumber: _quotationNumberController.text.trim(),
          quotationDate: _fmtDate(_quotationDate),
          validUntil: _fmtDate(_validUntil),
          discount: discount,
          taxRate: taxRate,
          deliveryDays: deliveryDays,
          paymentTerms: _paymentTermsController.text.trim(),
          notes: _notesController.text.trim(),
          items: items,
        );
      } else {
        q = await repo.createQuotation(
          widget.projectId,
          widget.rfqId,
          supplierId: _supplierId!,
          quotationNumber: _quotationNumberController.text.trim(),
          quotationDate: _fmtDate(_quotationDate),
          validUntil: _fmtDate(_validUntil),
          discount: discount,
          taxRate: taxRate,
          deliveryDays: deliveryDays,
          paymentTerms: _paymentTermsController.text.trim(),
          notes: _notesController.text.trim(),
          items: items,
        );
      }
      final rfqArgs = (projectId: widget.projectId, rfqId: widget.rfqId);
      ref.invalidate(rfqQuotationsProvider(rfqArgs));
      ref.invalidate(bidComparisonProvider(rfqArgs));
      if (widget.isEdit) {
        ref.invalidate(quotationDetailProvider((projectId: widget.projectId, rfqId: widget.rfqId, quotationId: widget.quotationId!)));
      }
      if (mounted) context.pop(q);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliersAsync = ref.watch(suppliersProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Teklifi Düzenle' : 'Yeni Teklif')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && _items.isEmpty)
              ? _RetryView(error: _error!, onRetry: () => setState(() {
                  _loading = true;
                  _error = null;
                  _load();
                }))
              : widget.isEdit
                  ? _buildForm(context, const [])
                  : suppliersAsync.when(
                      loading: () => const Center(child: CircularProgressIndicator()),
                      error: (e, _) => _RetryView(
                          error: e is ApiException ? e.message : 'Beklenmeyen bir hata oluştu.',
                          onRetry: () => ref.invalidate(suppliersProvider)),
                      data: (suppliers) => _buildForm(context, suppliers),
                    ),
    );
  }

  Widget _buildForm(BuildContext context, List<Supplier> suppliers) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.isEdit)
            _RowText('Tedarikçi', _supplierLabel ?? '-')
          else
            DropdownButtonFormField<String>(
              initialValue: _supplierId,
              decoration: const InputDecoration(labelText: 'Tedarikçi'),
              items: suppliers
                  .where((s) => s.isActive)
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
          TextFormField(
            controller: _quotationNumberController,
            decoration: const InputDecoration(labelText: 'Teklif No (opsiyonel)'),
          ),
          const SizedBox(height: 12),
          _DatePickerTile(
            label: 'Teklif Tarihi (opsiyonel)',
            value: _quotationDate,
            onChanged: (d) => setState(() => _quotationDate = d),
          ),
          _DatePickerTile(
            label: 'Geçerlilik Tarihi (opsiyonel)',
            value: _validUntil,
            onChanged: (d) => setState(() => _validUntil = d),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _discountController,
                  decoration: const InputDecoration(labelText: 'İskonto (tutar)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _taxRateController,
                  decoration: const InputDecoration(labelText: 'KDV Oranı (%)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _deliveryDaysController,
                  decoration: const InputDecoration(labelText: 'Teslimat Süresi (gün, opsiyonel)'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _paymentTermsController,
                  decoration: const InputDecoration(labelText: 'Ödeme Koşulları (opsiyonel)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Kalem Fiyatları', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ..._items.map((item) => _ItemRow(item: item, onChanged: () => setState(() {}))),
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
                : Text(widget.isEdit ? 'Kaydet' : 'Teklifi Kaydet'),
          ),
        ],
      ),
    );
  }
}

class _RowText extends StatelessWidget {
  const _RowText(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
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
  const _ItemRow({required this.item, required this.onChanged});

  final _DraftItem item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: item.quantity,
                    decoration: InputDecoration(labelText: 'Miktar (${item.unit})', isDense: true),
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

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';

class _DraftItem {
  _DraftItem();

  String costCodeId = '';
  String budgetLineId = '';
  String wbsNodeId = '';
  String description = '';
  String amount = '';

  factory _DraftItem.fromItem(SubcontractItem item) => _DraftItem()
    ..costCodeId = item.costCodeId
    ..budgetLineId = item.budgetLineId ?? ''
    ..wbsNodeId = item.wbsNodeId ?? ''
    ..description = item.description
    ..amount = _numStr(item.originalAmount);

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

/// Sprint 5 P1 — Taşeron Sözleşmesi Ekle/Düzenle. Create + Edit AYNI ekran
/// (bkz. `OfferCreateScreen` deseni) -- [subcontractId] doluysa
/// `PUT /subcontracts/{id}` (YALNIZCA `draft` durumunda kabul edilir).
///
/// Backend Update kalemleri HER SEFERİNDE tamamen yeniden yazar (sil-
/// yeniden-oluştur) -- bu yüzden edit modunda mevcut kalemler yüklenip
/// `_items`'a önceden doldurulur; kullanıcı dokunmasa bile submit'te
/// OLDUĞU GİBİ geri gönderilirler (bkz. `SubcontractItem.toJson` yorumu).
class SubcontractFormScreen extends ConsumerStatefulWidget {
  const SubcontractFormScreen({super.key, required this.projectId, this.subcontractId});

  final String projectId;
  final String? subcontractId;

  bool get isEdit => subcontractId != null;

  @override
  ConsumerState<SubcontractFormScreen> createState() => _SubcontractFormScreenState();
}

class _SubcontractFormScreenState extends ConsumerState<SubcontractFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _scopeController = TextEditingController();
  final _paymentTermsController = TextEditingController();
  final _notesController = TextEditingController();
  final _retentionController = TextEditingController();
  final _advanceController = TextEditingController();
  final List<_DraftItem> _items = [];
  String? _supplierId;
  DateTime? _effectiveDate;
  DateTime? _startDate;
  DateTime? _plannedCompletionDate;
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
      _items.add(_DraftItem());
    }
  }

  Future<void> _loadExisting() async {
    try {
      final detail =
          await ref.read(projectsRepositoryProvider).subcontractDetail(widget.projectId, widget.subcontractId!);
      if (!mounted) return;
      if (!detail.subcontract.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu sözleşme yalnızca taslak durumdayken düzenlenebilir.';
        });
        return;
      }
      final sc = detail.subcontract;
      _supplierId = sc.supplierId.isEmpty ? null : sc.supplierId;
      _titleController.text = sc.title;
      _scopeController.text = sc.scopeSummary;
      _paymentTermsController.text = sc.paymentTerms;
      _notesController.text = sc.notes;
      _retentionController.text = sc.retentionPercent != null ? _DraftItem._numStr(sc.retentionPercent!) : '';
      _advanceController.text = sc.advanceAmount != null ? _DraftItem._numStr(sc.advanceAmount!) : '';
      _effectiveDate = _parseDate(sc.effectiveDate);
      _startDate = _parseDate(sc.startDate);
      _plannedCompletionDate = _parseDate(sc.plannedCompletionDate);
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
    _titleController.dispose();
    _scopeController.dispose();
    _paymentTermsController.dispose();
    _notesController.dispose();
    _retentionController.dispose();
    _advanceController.dispose();
    super.dispose();
  }

  List<SubcontractItem> _buildItems() {
    final out = <SubcontractItem>[];
    for (final i in _items) {
      final amt = double.tryParse(i.amount.replaceAll(',', '.'));
      if (i.costCodeId.isEmpty || i.description.trim().isEmpty || amt == null || amt <= 0) continue;
      out.add(SubcontractItem(
        id: '',
        wbsNodeId: i.wbsNodeId.isEmpty ? null : i.wbsNodeId,
        costCodeId: i.costCodeId,
        budgetLineId: i.budgetLineId.isEmpty ? null : i.budgetLineId,
        description: i.description.trim(),
        quantity: null,
        unit: '',
        unitPrice: null,
        originalAmount: amt,
        sortOrder: 0,
      ));
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_supplierId == null || _supplierId!.isEmpty) {
      setState(() => _error = 'Tedarikçi (taşeron) seçin.');
      return;
    }
    final items = _buildItems();
    if (items.isEmpty) {
      setState(() => _error = 'En az bir geçerli SOV kalemi girin (maliyet kodu, açıklama, tutar > 0).');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final Subcontract sc;
      if (widget.isEdit) {
        sc = await repo.updateSubcontract(
          widget.projectId,
          widget.subcontractId!,
          supplierId: _supplierId!,
          title: _titleController.text.trim(),
          scopeSummary: _scopeController.text.trim(),
          effectiveDate: _fmtDate(_effectiveDate),
          startDate: _fmtDate(_startDate),
          plannedCompletionDate: _fmtDate(_plannedCompletionDate),
          retentionPercent: double.tryParse(_retentionController.text.replaceAll(',', '.')),
          advanceAmount: double.tryParse(_advanceController.text.replaceAll(',', '.')),
          paymentTerms: _paymentTermsController.text.trim(),
          notes: _notesController.text.trim(),
          items: items,
        );
      } else {
        sc = await repo.createSubcontract(
          widget.projectId,
          supplierId: _supplierId!,
          title: _titleController.text.trim(),
          scopeSummary: _scopeController.text.trim(),
          effectiveDate: _fmtDate(_effectiveDate),
          startDate: _fmtDate(_startDate),
          plannedCompletionDate: _fmtDate(_plannedCompletionDate),
          retentionPercent: double.tryParse(_retentionController.text.replaceAll(',', '.')),
          advanceAmount: double.tryParse(_advanceController.text.replaceAll(',', '.')),
          paymentTerms: _paymentTermsController.text.trim(),
          notes: _notesController.text.trim(),
          items: items,
        );
      }
      ref.invalidate(projectSubcontractsProvider(widget.projectId));
      if (widget.isEdit) {
        ref.invalidate(
          subcontractDetailProvider((projectId: widget.projectId, subcontractId: widget.subcontractId!)),
        );
      }
      if (mounted) context.go('/projeler/${widget.projectId}/taseronlar/${sc.id}');
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
      appBar: AppBar(title: Text(widget.isEdit ? 'Taşeron Sözleşmesini Düzenle' : 'Yeni Taşeron Sözleşmesi')),
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
          DropdownButtonFormField<String>(
            initialValue: _supplierId,
            decoration: const InputDecoration(labelText: 'Tedarikçi (Taşeron)'),
            items: suppliers
                .where((s) => s.isActive || s.id == _supplierId)
                .map((s) => DropdownMenuItem(
                      value: s.id,
                      child: Text(
                        s.code.isNotEmpty ? '${s.code} — ${s.displayName}' : s.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _supplierId = v),
            validator: (v) => (v == null || v.isEmpty) ? 'Tedarikçi seçin' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Başlık'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Başlık gerekli' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _scopeController,
            decoration: const InputDecoration(labelText: 'Kapsam Özeti (opsiyonel)'),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          _DatePickerTile(
            label: 'Yürürlük Tarihi (opsiyonel)',
            value: _effectiveDate,
            onChanged: (d) => setState(() => _effectiveDate = d),
          ),
          _DatePickerTile(
            label: 'Başlangıç Tarihi (opsiyonel)',
            value: _startDate,
            onChanged: (d) => setState(() => _startDate = d),
          ),
          _DatePickerTile(
            label: 'Planlanan Bitiş Tarihi (opsiyonel)',
            value: _plannedCompletionDate,
            onChanged: (d) => setState(() => _plannedCompletionDate = d),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _retentionController,
                  decoration: const InputDecoration(labelText: 'Hakediş Kesintisi % (opsiyonel)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _advanceController,
                  decoration: const InputDecoration(labelText: 'Avans Tutarı (opsiyonel)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _paymentTermsController,
            decoration: const InputDecoration(labelText: 'Ödeme Koşulları (opsiyonel)'),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('SOV / İş Kalemleri', style: TextStyle(fontWeight: FontWeight.w700)),
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
                : Text(widget.isEdit ? 'Kaydet' : 'Sözleşmeyi Oluştur'),
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
            TextFormField(
              initialValue: item.amount,
              decoration: const InputDecoration(labelText: 'Tutar', isDense: true),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (v) {
                item.amount = v;
                onChanged();
              },
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

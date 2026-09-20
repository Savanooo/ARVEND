import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../domain/subcontract.dart' show OrgCostCode;

class _DraftItem {
  _DraftItem();

  String costCodeId = '';
  String description = '';
  String quantity = '';
  String unit = '';
  String estimatedUnitCost = '';

  factory _DraftItem.fromItem(PurchaseRequestItem item) => _DraftItem()
    ..costCodeId = item.costCodeId ?? ''
    ..description = item.description
    ..quantity = _numStr(item.quantity)
    ..unit = item.unit
    ..estimatedUnitCost = item.estimatedUnitCost != null ? _numStr(item.estimatedUnitCost!) : '';

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

/// P3 — Satın Alma Talebi Ekle/Düzenle. Create + Edit AYNI ekran (bkz.
/// `SubcontractFormScreen` deseni). Kalemler OPSİYONELDİR (backend boş bir
/// talep oluşturmaya izin verir) ama Submit >=1 kalem ister -- bu yüzden
/// burada minimum 1 satır gösterilir, tamamen boş bırakılırsa Submit
/// aşamasında backend reddeder (bkz. Phase 1 doğrulaması). Maliyet kodu HER
/// ZAMAN opsiyoneldir (P1'deki WBS/bütçe kalemi sınırı burada da korunur --
/// yalnızca maliyet kodu picker'ı sunulur).
class PurchaseRequestFormScreen extends ConsumerStatefulWidget {
  const PurchaseRequestFormScreen({super.key, required this.projectId, this.prId});

  final String projectId;
  final String? prId;

  bool get isEdit => prId != null;

  @override
  ConsumerState<PurchaseRequestFormScreen> createState() => _PurchaseRequestFormScreenState();
}

class _PurchaseRequestFormScreenState extends ConsumerState<PurchaseRequestFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final List<_DraftItem> _items = [];
  DateTime? _neededBy;
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
      final detail = await ref.read(projectsRepositoryProvider).purchaseRequestDetail(widget.projectId, widget.prId!);
      if (!mounted) return;
      if (!detail.request.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu talep yalnızca taslak durumdayken düzenlenebilir.';
        });
        return;
      }
      _titleController.text = detail.request.title;
      _descriptionController.text = detail.request.description;
      _neededBy = _parseDate(detail.request.neededBy);
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
    _descriptionController.dispose();
    super.dispose();
  }

  List<PurchaseRequestItem> _buildItems() {
    final out = <PurchaseRequestItem>[];
    for (final i in _items) {
      final qty = double.tryParse(i.quantity.replaceAll(',', '.'));
      if (i.description.trim().isEmpty || qty == null || qty <= 0) continue;
      final unitCost = double.tryParse(i.estimatedUnitCost.replaceAll(',', '.'));
      out.add(PurchaseRequestItem(
        id: '',
        wbsNodeId: null,
        costCodeId: i.costCodeId.isEmpty ? null : i.costCodeId,
        budgetLineId: null,
        description: i.description.trim(),
        quantity: qty,
        unit: i.unit,
        estimatedUnitCost: unitCost,
        // Mobil ayrı bir "tahmini toplam" alanı SUNMAZ -- birim fiyat
        // verildiğinde backend'in KENDİSİ qty*unitCost'u yeniden hesaplar
        // ve bu değeri YOKSAYAR (bkz. Phase 1: estimated_total yalnızca
        // unitCost boşken bir yedek olarak kullanılır).
        estimatedTotal: 0,
        notes: '',
        sortOrder: 0,
      ));
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final items = _buildItems();

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final PurchaseRequest pr;
      if (widget.isEdit) {
        pr = await repo.updatePurchaseRequest(
          widget.projectId,
          widget.prId!,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          neededBy: _fmtDate(_neededBy),
          items: items,
        );
      } else {
        pr = await repo.createPurchaseRequest(
          widget.projectId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          neededBy: _fmtDate(_neededBy),
          items: items,
        );
      }
      ref.invalidate(projectPurchaseRequestsProvider(widget.projectId));
      if (widget.isEdit) {
        ref.invalidate(purchaseRequestDetailProvider((projectId: widget.projectId, prId: widget.prId!)));
      }
      if (mounted) context.go('/projeler/${widget.projectId}/satin-alma/talepler/${pr.id}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final costCodesAsync = ref.watch(orgCostCodesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Talebi Düzenle' : 'Yeni Satın Alma Talebi')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : costCodesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _RetryView(error: e, onRetry: () => ref.invalidate(orgCostCodesProvider)),
              data: (costCodes) => _buildForm(context, costCodes),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<OrgCostCode> costCodes) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Başlık'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Başlık gerekli' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('İhtiyaç Tarihi (opsiyonel)'),
            subtitle: _neededBy != null
                ? Text(
                    '${_neededBy!.day.toString().padLeft(2, '0')}.${_neededBy!.month.toString().padLeft(2, '0')}.${_neededBy!.year}')
                : null,
            trailing: _neededBy != null
                ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _neededBy = null))
                : const Icon(Icons.calendar_today_outlined, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _neededBy ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _neededBy = picked);
            },
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Talep Edilen Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Kalem Ekle'),
                onPressed: () => setState(() => _items.add(_DraftItem())),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Kalemler opsiyoneldir, ama talebi göndermek için en az bir geçerli kalem gerekir.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
          ),
          ..._items.asMap().entries.map((entry) => _ItemRow(
                item: entry.value,
                costCodes: costCodes,
                onChanged: () => setState(() {}),
                onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
              )),
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
                : Text(widget.isEdit ? 'Kaydet' : 'Talebi Oluştur'),
          ),
        ],
      ),
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
                  child: TextFormField(
                    initialValue: item.description,
                    decoration: const InputDecoration(labelText: 'Açıklama', isDense: true),
                    onChanged: (v) {
                      item.description = v;
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
              ],
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
                    initialValue: item.estimatedUnitCost,
                    decoration: const InputDecoration(labelText: 'Tahmini Br. Fiyat', isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      item.estimatedUnitCost = v;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: item.costCodeId.isEmpty ? null : item.costCodeId,
              decoration: const InputDecoration(labelText: 'Maliyet Kodu (opsiyonel)', isDense: true),
              items: [
                const DropdownMenuItem(value: '', child: Text('— Seçilmedi —')),
                ...costCodes
                    .where((c) => c.isActive || c.id == item.costCodeId)
                    .map((c) => DropdownMenuItem(value: c.id, child: Text('${c.code} — ${c.name}', overflow: TextOverflow.ellipsis))),
              ],
              onChanged: (v) {
                item.costCodeId = v ?? '';
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../domain/subcontract.dart' show OrgCostCode;
import 'form_number_input.dart';

class _DraftItem {
  _DraftItem();

  String costCodeId = '';
  String description = '';
  String quantity = '';
  String unit = '';
  String estimatedUnitCost = '';

  /// Formda seçici yok ama mevcut kalemden KORUNUR: PUT kalemleri tümden
  /// yeniden yazdığı için gönderilmezse web'de bağlanmış bütçe kalemi/WBS/not ve (birim fiyatsız
  /// kalemde tek kaynak olan) tahmini toplam
  /// mobilde düzenlenen taslakta sessizce silinirdi.
  String? wbsNodeId;
  String? budgetLineId;
  String notes = '';
  double estimatedTotal = 0;

  factory _DraftItem.fromItem(PurchaseRequestItem item) => _DraftItem()
    ..costCodeId = item.costCodeId ?? ''
    ..wbsNodeId = item.wbsNodeId
    ..budgetLineId = item.budgetLineId
    ..notes = item.notes
    ..estimatedTotal = item.estimatedTotal
    ..description = item.description
    ..quantity = formNumberText(item.quantity)
    ..unit = item.unit
    ..estimatedUnitCost = formNumberText(item.estimatedUnitCost);

  /// Hiç dokunulmamış satır gönderilmez; yarım ya da geçersiz satır kendi
  /// alanında hata gösterir ve kaydı durdurur (eskiden sessizce atlanırdı).
  bool get isBlank =>
      description.trim().isEmpty && quantity.trim().isEmpty && estimatedUnitCost.trim().isEmpty;
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

  /// Form doğrulandıktan SONRA çağrılır: boş olmayan her satır geçerlidir.
  List<PurchaseRequestItem> _buildItems() => [
        for (final i in _items)
          if (!i.isBlank)
            PurchaseRequestItem(
              id: '',
              wbsNodeId: i.wbsNodeId,
              costCodeId: i.costCodeId.isEmpty ? null : i.costCodeId,
              budgetLineId: i.budgetLineId,
              description: i.description.trim(),
              quantity: parseFormNumber(i.quantity)!,
              unit: i.unit,
              estimatedUnitCost: parseFormNumber(i.estimatedUnitCost),
              // Mobil ayrı bir "tahmini toplam" alanı SUNMAZ -- birim fiyat
              // verildiğinde backend'in KENDİSİ qty*unitCost'u yeniden hesaplar
              // ve bu değeri YOKSAYAR (bkz. Phase 1: estimated_total yalnızca
              // unitCost boşken bir yedek olarak kullanılır). Birim fiyatsız
              // mevcut bir kalemin (web'den girilmiş) toplamı bu yüzden korunur.
              estimatedTotal: i.estimatedTotal,
              notes: i.notes,
              sortOrder: 0,
            ),
      ];

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

    return AppPageScaffold(
      title: Text(widget.isEdit ? 'Talebi Düzenle' : 'Yeni Satın Alma Talebi'),
      body: _loading
          ? const LoadingState()
          : AsyncStateView(
              value: costCodesAsync,
              onRetry: () async => ref.invalidate(orgCostCodesProvider),
              data: (context, costCodes) => _buildForm(context, costCodes),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<OrgCostCode> costCodes) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppFormSection(
            title: 'Temel Bilgiler',
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Başlık'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Başlık gerekli' : null,
              ),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
                maxLines: 3,
              ),
              _NeededByField(
                value: _neededBy,
                onChanged: (v) => setState(() => _neededBy = v),
              ),
            ],
          ),
          AppFormSection(
            title: 'Kalemler',
            subtitle: 'Kalemler opsiyoneldir, ama talebi göndermek için en az bir geçerli kalem gerekir.',
            children: [
              ..._items.asMap().entries.map((entry) => _ItemRow(
                    key: ObjectKey(entry.value),
                    item: entry.value,
                    costCodes: costCodes,
                    onChanged: () => setState(() {}),
                    onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
                  )),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Kalem Ekle'),
                  onPressed: () => setState(() => _items.add(_DraftItem())),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            Text(_error!, style: AppTypography.error),
            const SizedBox(height: AppSpacing.md),
          ],
          PrimaryButton(
            label: widget.isEdit ? 'Kaydet' : 'Talebi Oluştur',
            loading: _submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

/// Talep formundaki "İhtiyaç Tarihi" alanı -- diğer `TextFormField`larla
/// tutarlı görünmesi için standart alan dekorasyonunu (bkz. AppTheme
/// `inputDecorationTheme`) bir `InputDecorator` ile paylaşır.
class _NeededByField extends StatelessWidget {
  const _NeededByField({required this.value, required this.onChanged});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'İhtiyaç Tarihi (opsiyonel)',
          suffixIcon: value != null
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        isEmpty: value == null,
        child: value == null
            ? null
            : Text(
                '${value!.day.toString().padLeft(2, '0')}.${value!.month.toString().padLeft(2, '0')}.${value!.year}',
                style: AppTypography.body,
              ),
      ),
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
                child: TextFormField(
                  initialValue: item.description,
                  decoration: const InputDecoration(labelText: 'Açıklama', isDense: true),
                  validator: (v) => item.isBlank || (v ?? '').trim().isNotEmpty ? null : 'Açıklama gerekli',
                  onChanged: (v) {
                    item.description = v;
                    onChanged();
                  },
                ),
              ),
              if (onRemove != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
            ],
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
                  initialValue: item.estimatedUnitCost,
                  decoration: const InputDecoration(labelText: 'Tahmini Br. Fiyat', isDense: true, errorMaxLines: 3),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => item.isBlank ? null : formNumberError(v, required: false, allowZero: true),
                  onChanged: (v) {
                    item.estimatedUnitCost = v;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
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
    );
  }
}

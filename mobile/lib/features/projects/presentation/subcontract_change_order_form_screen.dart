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
import '../domain/subcontract.dart';
import 'form_number_input.dart';

class _DraftItem {
  _DraftItem();

  String costCodeId = '';
  String description = '';
  String amount = '';

  factory _DraftItem.fromItem(SubcontractChangeOrderItem item) => _DraftItem()
    ..costCodeId = item.costCodeId
    ..description = item.description
    ..amount = formNumberText(item.amount);

  /// Hiç dokunulmamış satır gönderilmez; yarım ya da geçersiz satır kendi
  /// alanında hata gösterir ve kaydı durdurur (eskiden sessizce atlanırdı).
  bool get isBlank => costCodeId.isEmpty && description.trim().isEmpty && amount.trim().isEmpty;
}

/// Sprint 5 P2 — Taşeron Değişiklik Emri Ekle/Düzenle. Create + Edit AYNI
/// ekran (bkz. `SubcontractFormScreen` deseni). Maliyet kodu seçimi P1'deki
/// `orgCostCodesProvider`'ı YENİDEN KULLANIR -- mobil bir WBS/bütçe kalemi
/// seçici SUNMAZ (P1'in bilinçli kapsam sınırı, bu görevde de korunur),
/// ikisi de opsiyonel boş bırakılır.
class SubcontractChangeOrderFormScreen extends ConsumerStatefulWidget {
  const SubcontractChangeOrderFormScreen({
    super.key,
    required this.projectId,
    required this.subcontractId,
    this.changeOrderId,
  });

  final String projectId;
  final String subcontractId;
  final String? changeOrderId;

  bool get isEdit => changeOrderId != null;

  @override
  ConsumerState<SubcontractChangeOrderFormScreen> createState() => _SubcontractChangeOrderFormScreenState();
}

class _SubcontractChangeOrderFormScreenState extends ConsumerState<SubcontractChangeOrderFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _reasonController = TextEditingController();
  final List<_DraftItem> _items = [];
  String _changeType = SubcontractChangeOrder.typeAddition;
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
          await ref.read(projectsRepositoryProvider).subcontractChangeOrderDetail(widget.projectId, widget.changeOrderId!);
      if (!mounted) return;
      if (!detail.changeOrder.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu değişiklik emri yalnızca taslak durumdayken düzenlenebilir.';
        });
        return;
      }
      final co = detail.changeOrder;
      _titleController.text = co.title;
      _descriptionController.text = co.description;
      _reasonController.text = co.reason;
      _changeType = co.changeType;
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
    _reasonController.dispose();
    super.dispose();
  }

  /// Form doğrulandıktan SONRA çağrılır: boş olmayan her satır geçerlidir.
  List<SubcontractChangeOrderItem> _buildItems() => [
        for (final i in _items)
          if (!i.isBlank)
            SubcontractChangeOrderItem(
              id: '',
              wbsNodeId: null,
              costCodeId: i.costCodeId,
              budgetLineId: null,
              description: i.description.trim(),
              amount: parseFormNumber(i.amount)!,
              sortOrder: 0,
            ),
      ];

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final items = _buildItems();
    if (items.isEmpty) {
      setState(() => _error = 'En az bir geçerli kalem girin (maliyet kodu, açıklama, tutar > 0).');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final SubcontractChangeOrder co;
      if (widget.isEdit) {
        co = await repo.updateSubcontractChangeOrder(
          widget.projectId,
          widget.changeOrderId!,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          changeType: _changeType,
          reason: _reasonController.text.trim(),
          items: items,
        );
      } else {
        co = await repo.createSubcontractChangeOrder(
          widget.projectId,
          widget.subcontractId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          changeType: _changeType,
          reason: _reasonController.text.trim(),
          items: items,
        );
      }
      final scArgs = (projectId: widget.projectId, subcontractId: widget.subcontractId);
      ref.invalidate(subcontractChangeOrdersProvider(scArgs));
      ref.invalidate(subcontractDetailProvider(scArgs));
      if (widget.isEdit) {
        ref.invalidate(subcontractChangeOrderDetailProvider((projectId: widget.projectId, changeOrderId: widget.changeOrderId!)));
      }
      if (mounted) {
        context.go('/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/degisiklik-emirleri/${co.id}');
      }
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
      title: Text(widget.isEdit ? 'Değişiklik Emrini Düzenle' : 'Yeni Değişiklik Emri'),
      body: _loading
          ? const LoadingState()
          : costCodesAsync.when(
              loading: () => const LoadingState(),
              error: (e, _) => ErrorState(error: e, onRetry: () async => ref.invalidate(orgCostCodesProvider)),
              data: (costCodes) => _buildForm(context, costCodes),
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
              DropdownButtonFormField<String>(
                initialValue: _changeType,
                decoration: const InputDecoration(labelText: 'Tür'),
                items: const [
                  DropdownMenuItem(value: SubcontractChangeOrder.typeAddition, child: Text('Ek İş (+)')),
                  DropdownMenuItem(value: SubcontractChangeOrder.typeDeduction, child: Text('Kesinti (-)')),
                ],
                onChanged: (v) => setState(() => _changeType = v ?? SubcontractChangeOrder.typeAddition),
              ),
              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(labelText: 'Gerekçe (opsiyonel)'),
              ),
            ],
          ),
          AppFormSection(
            title: 'Kalemler',
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Kalem Ekle'),
                  onPressed: () => setState(() => _items.add(_DraftItem())),
                ),
              ),
              ..._items.asMap().entries.map((entry) => _ItemRow(
                    key: ObjectKey(entry.value),
                    item: entry.value,
                    costCodes: costCodes,
                    onChanged: () => setState(() {}),
                    onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
                  )),
            ],
          ),
          if (_error != null) ...[
            Text(_error!, style: AppTypography.error),
            const SizedBox(height: AppSpacing.md),
          ],
          PrimaryButton(
            label: widget.isEdit ? 'Kaydet' : 'Değişiklik Emri Oluştur',
            loading: _submitting,
            onPressed: _submit,
          ),
        ],
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
      margin: const EdgeInsets.only(top: AppSpacing.sm),
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
          TextFormField(
            initialValue: item.amount,
            decoration: const InputDecoration(labelText: 'Tutar', isDense: true),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (v) => item.isBlank ? null : formNumberError(v),
            onChanged: (v) {
              item.amount = v;
              onChanged();
            },
          ),
        ],
      ),
    );
  }
}

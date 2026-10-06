import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shadows.dart';
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

  /// Formda seçici yok ama mevcut kalemden KORUNUR: PUT kalemleri tümden
  /// yeniden yazdığı için gönderilmezse web'de bağlanmış bütçe kalemi/WBS
  /// mobilde düzenlenen taslakta sessizce silinirdi.
  String? wbsNodeId;
  String? budgetLineId;

  factory _DraftItem.fromItem(RFQItem item) => _DraftItem()
    ..costCodeId = item.costCodeId ?? ''
    ..wbsNodeId = item.wbsNodeId
    ..budgetLineId = item.budgetLineId
    ..description = item.description
    ..quantity = formNumberText(item.quantity)
    ..unit = item.unit;

  /// Hiç dokunulmamış satır gönderilmez; yarım ya da geçersiz satır kendi
  /// alanında hata gösterir ve kaydı durdurur (eskiden sessizce atlanırdı).
  bool get isBlank => description.trim().isEmpty && quantity.trim().isEmpty;
}

String? _fmtDate(DateTime? d) {
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// P3 — RFQ Ekle/Düzenle. Create + Edit AYNI ekran. Bir onaylı Talepten
/// (Purchase Request) seçilirse kalemler backend'de o talepten SNAPSHOT
/// KOPYALANIR ve bu formun kendi kalem listesi YOKSAYILIR -- bu yüzden PR
/// seçiliyken kalem bölümü GİZLENİR (bkz. Phase 1 doğrulaması). PR
/// seçilmezse kalemler doğrudan bu formdan girilir.
class RFQFormScreen extends ConsumerStatefulWidget {
  const RFQFormScreen({super.key, required this.projectId, this.rfqId});

  final String projectId;
  final String? rfqId;

  bool get isEdit => rfqId != null;

  @override
  ConsumerState<RFQFormScreen> createState() => _RFQFormScreenState();
}

class _RFQFormScreenState extends ConsumerState<RFQFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final List<_DraftItem> _items = [];
  final Set<String> _supplierIds = {};
  String? _purchaseRequestId;
  DateTime? _issueDate;
  DateTime? _dueDate;
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
      _issueDate = DateTime.now();
      _items.add(_DraftItem());
    }
  }

  Future<void> _loadExisting() async {
    try {
      final detail = await ref
          .read(projectsRepositoryProvider)
          .rfqDetail(widget.projectId, widget.rfqId!);
      if (!mounted) return;
      if (!detail.rfq.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu RFQ yalnızca taslak durumdayken düzenlenebilir.';
        });
        return;
      }
      _titleController.text = detail.rfq.title;
      _notesController.text = detail.rfq.notes;
      _purchaseRequestId = detail.rfq.purchaseRequestId;
      _issueDate = _parseDate(detail.rfq.issueDate);
      _dueDate = _parseDate(detail.rfq.dueDate);
      _supplierIds
        ..clear()
        ..addAll(detail.suppliers.map((s) => s.supplierId));
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
    _notesController.dispose();
    super.dispose();
  }

  /// Form doğrulandıktan SONRA çağrılır: boş olmayan her satır geçerlidir.
  List<RFQItem> _buildItems() => [
        for (final i in _items)
          if (!i.isBlank)
            RFQItem(
              id: '',
              sourcePrItemId: null,
              wbsNodeId: i.wbsNodeId,
              costCodeId: i.costCodeId.isEmpty ? null : i.costCodeId,
              budgetLineId: i.budgetLineId,
              description: i.description.trim(),
              quantity: parseFormNumber(i.quantity)!,
              unit: i.unit,
              sortOrder: 0,
            ),
      ];

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final usesPr = _purchaseRequestId != null && _purchaseRequestId!.isNotEmpty;
    final items = usesPr ? const <RFQItem>[] : _buildItems();
    if (!usesPr && items.isEmpty) {
      setState(
        () => _error =
            'Bir Satın Alma Talebi seçin veya en az bir geçerli kalem girin.',
      );
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final RFQ rfq;
      if (widget.isEdit) {
        rfq = await repo.updateRFQ(
          widget.projectId,
          widget.rfqId!,
          title: _titleController.text.trim(),
          purchaseRequestId: _purchaseRequestId,
          issueDate: _fmtDate(_issueDate),
          dueDate: _fmtDate(_dueDate),
          notes: _notesController.text.trim(),
          supplierIds: _supplierIds.toList(),
          items: items,
        );
      } else {
        rfq = await repo.createRFQ(
          widget.projectId,
          title: _titleController.text.trim(),
          purchaseRequestId: _purchaseRequestId,
          issueDate: _fmtDate(_issueDate),
          dueDate: _fmtDate(_dueDate),
          notes: _notesController.text.trim(),
          supplierIds: _supplierIds.toList(),
          items: items,
        );
      }
      ref.invalidate(projectRFQsProvider(widget.projectId));
      if (widget.isEdit) {
        ref.invalidate(
          rfqDetailProvider((
            projectId: widget.projectId,
            rfqId: widget.rfqId!,
          )),
        );
      }
      if (mounted) {
        context.go('/projeler/${widget.projectId}/satin-alma/rfqlar/${rfq.id}');
      }
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
    final approvedPrsAsync = ref.watch(
      projectPurchaseRequestsProvider(widget.projectId),
    );

    return AppPageScaffold(
      title: Text(widget.isEdit ? 'RFQ Düzenle' : 'Yeni RFQ'),
      body: _loading
          ? const LoadingState()
          : suppliersAsync.when(
              loading: () => const LoadingState(),
              error: (e, _) => ErrorState(
                error: e,
                onRetry: () async => ref.invalidate(suppliersProvider),
              ),
              data: (suppliers) => costCodesAsync.when(
                loading: () => const LoadingState(),
                error: (e, _) => ErrorState(
                  error: e,
                  onRetry: () async => ref.invalidate(orgCostCodesProvider),
                ),
                data: (costCodes) => approvedPrsAsync.when(
                  loading: () => const LoadingState(),
                  error: (e, _) => ErrorState(
                    error: e,
                    onRetry: () async => ref.invalidate(
                      projectPurchaseRequestsProvider(widget.projectId),
                    ),
                  ),
                  data: (prs) => _buildForm(
                    context,
                    suppliers,
                    costCodes,
                    prs
                        .where(
                          (p) => p.status == PurchaseRequest.statusApproved,
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    List<Supplier> suppliers,
    List<OrgCostCode> costCodes,
    List<PurchaseRequest> approvedPrs,
  ) {
    final usesPr = _purchaseRequestId != null && _purchaseRequestId!.isNotEmpty;
    return Form(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                AppFormSection(
                  title: 'Temel Bilgiler',
                  children: [
                    TextFormField(
                      controller: _titleController,
                      decoration: const InputDecoration(labelText: 'Başlık'),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Başlık gerekli'
                          : null,
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: usesPr ? _purchaseRequestId : '',
                      decoration: const InputDecoration(
                        labelText: 'Kaynak Satın Alma Talebi (opsiyonel)',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('— Kendi kalemlerimi gireceğim —'),
                        ),
                        ...approvedPrs.map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text('${p.prNo} — ${p.title}'),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(
                        () => _purchaseRequestId = (v == null || v.isEmpty)
                            ? null
                            : v,
                      ),
                    ),
                    if (usesPr)
                      Text(
                        'Kalemler seçilen talepten otomatik kopyalanır -- burada ayrıca kalem girilmez.',
                        style: AppTypography.helper,
                      ),
                    _DatePickerTile(
                      label: 'Yayın Tarihi (opsiyonel)',
                      value: _issueDate,
                      onChanged: (d) => setState(() => _issueDate = d),
                    ),
                    _DatePickerTile(
                      label: 'Son Yanıt Tarihi (opsiyonel)',
                      value: _dueDate,
                      onChanged: (d) => setState(() => _dueDate = d),
                    ),
                    TextFormField(
                      controller: _notesController,
                      decoration: const InputDecoration(
                        labelText: 'Notlar (opsiyonel)',
                      ),
                      maxLines: 3,
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Davet Edilecek Tedarikçiler',
                  subtitle:
                      'RFQ oluştururken opsiyonel; Yayınlamak için en az bir tedarikçi gereklidir.',
                  children: [
                    AppCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      child: Column(
                        children: suppliers
                            .where((s) => s.isActive)
                            .map(
                              (s) => CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  s.code.isNotEmpty
                                      ? '${s.code} — ${s.displayName}'
                                      : s.displayName,
                                ),
                                value: _supplierIds.contains(s.id),
                                onChanged: (checked) => setState(() {
                                  if (checked ?? false) {
                                    _supplierIds.add(s.id);
                                  } else {
                                    _supplierIds.remove(s.id);
                                  }
                                }),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
                if (!usesPr)
                  AppFormSection(
                    title: 'Kalemler',
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Kalem Ekle'),
                          onPressed: () =>
                              setState(() => _items.add(_DraftItem())),
                        ),
                      ),
                      ..._items.asMap().entries.map(
                        (entry) => _ItemRow(
                          key: ObjectKey(entry.value),
                          item: entry.value,
                          costCodes: costCodes,
                          onChanged: () => setState(() {}),
                          onRemove: _items.length > 1
                              ? () => setState(() => _items.removeAt(entry.key))
                              : null,
                        ),
                      ),
                    ],
                  ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_error!, style: AppTypography.error),
                ],
              ],
            ),
          ),
          _StickyActionBar(
            child: PrimaryButton(
              label: widget.isEdit ? 'Kaydet' : 'RFQ Oluştur',
              loading: _submitting,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// Formun altına sabitlenmiş aksiyon çubuğu (bkz. offer_create_screen.dart
/// AYNI kalıp) -- kaydet butonuna ulaşmak için listenin sonuna kadar
/// kaydırmayı GEREKTİRMEZ.
class _StickyActionBar extends StatelessWidget {
  const _StickyActionBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: AppShadows.subtle,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md + MediaQuery.of(context).padding.bottom,
        ),
        child: child,
      ),
    );
  }
}

class _DatePickerTile extends StatelessWidget {
  const _DatePickerTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: value != null
          ? Text(
              '${value!.day.toString().padLeft(2, '0')}.${value!.month.toString().padLeft(2, '0')}.${value!.year}',
            )
          : null,
      trailing: value != null
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => onChanged(null),
            )
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
  const _ItemRow({
    super.key,
    required this.item,
    required this.costCodes,
    required this.onChanged,
    this.onRemove,
  });

  final _DraftItem item;
  final List<OrgCostCode> costCodes;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: item.description,
                  decoration: const InputDecoration(
                    labelText: 'Açıklama',
                    isDense: true,
                  ),
                  validator: (v) => item.isBlank || (v ?? '').trim().isNotEmpty
                      ? null
                      : 'Açıklama gerekli',
                  onChanged: (v) {
                    item.description = v;
                    onChanged();
                  },
                ),
              ),
              if (onRemove != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onRemove,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: item.quantity,
                  decoration: const InputDecoration(
                    labelText: 'Miktar',
                    isDense: true,
                    errorMaxLines: 3,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
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
                  decoration: const InputDecoration(
                    labelText: 'Birim',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    item.unit = v;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            initialValue: item.costCodeId.isEmpty ? null : item.costCodeId,
            decoration: const InputDecoration(
              labelText: 'Maliyet Kodu (opsiyonel)',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('— Seçilmedi —')),
              ...costCodes
                  .where((c) => c.isActive || c.id == item.costCodeId)
                  .map(
                    (c) => DropdownMenuItem(
                      value: c.id,
                      child: Text(
                        '${c.code} — ${c.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
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

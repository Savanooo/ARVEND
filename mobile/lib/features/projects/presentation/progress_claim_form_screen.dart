import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/utils/form_exit.dart';
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

  String subcontractItemId = '';
  String description = '';
  String amount = '';

  factory _DraftItem.fromClaimItem(ProgressClaimItem item) => _DraftItem()
    ..subcontractItemId = item.subcontractItemId
    ..description = item.itemDescription
    ..amount = formNumberText(item.currentProgressAmount);

  /// Hiç dokunulmamış satır gönderilmez; yarım ya da geçersiz satır kendi
  /// alanında hata gösterir ve kaydı durdurur (eskiden sessizce atlanırdı).
  bool get isBlank => subcontractItemId.isEmpty && amount.trim().isEmpty;
}

String? _fmtDate(DateTime? d) {
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// Sprint 5 P2 — Hakediş Ekle/Düzenle. Create + Edit AYNI ekran (bkz.
/// `SubcontractFormScreen`/`OfferCreateScreen` deseni). Backend `period_end`i
/// JSON tag'de zorunlu gösterir ama SUNUCU TARAFINDA doğrulamaz (boş/geçersiz
/// tarih sessizce 0001-01-01'e düşer, bkz. Phase 1 bulgusu) -- bu yüzden
/// burada Form validator'ı İLE istemci tarafında ZORUNLU kılınır.
class ProgressClaimFormScreen extends ConsumerStatefulWidget {
  const ProgressClaimFormScreen({super.key, required this.projectId, required this.subcontractId, this.claimId});

  final String projectId;
  final String subcontractId;
  final String? claimId;

  bool get isEdit => claimId != null;

  @override
  ConsumerState<ProgressClaimFormScreen> createState() => _ProgressClaimFormScreenState();
}

class _ProgressClaimFormScreenState extends ConsumerState<ProgressClaimFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _retentionController = TextEditingController();
  final _advanceController = TextEditingController();
  final _deductionsController = TextEditingController();
  final _notesController = TextEditingController();
  final List<_DraftItem> _items = [];
  DateTime? _periodStart;
  DateTime? _periodEnd;
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
      WidgetsBinding.instance.addPostFrameCallback((_) => _prefillRetentionFromSubcontract());
    }
  }

  Future<void> _prefillRetentionFromSubcontract() async {
    final scArgs = (projectId: widget.projectId, subcontractId: widget.subcontractId);
    final sc = await ref.read(subcontractDetailProvider(scArgs).future);
    if (!mounted) return;
    _retentionController.text = sc.subcontract.retentionPercent != null
        ? formNumberText(sc.subcontract.retentionPercent!)
        : '0';
  }

  Future<void> _loadExisting() async {
    try {
      final detail = await ref.read(projectsRepositoryProvider).progressClaimDetail(widget.projectId, widget.claimId!);
      if (!mounted) return;
      if (!detail.claim.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu hakediş yalnızca taslak durumdayken düzenlenebilir.';
        });
        return;
      }
      final claim = detail.claim;
      _periodStart = _parseDate(claim.periodStart);
      _periodEnd = _parseDate(claim.periodEnd);
      _retentionController.text = formNumberText(claim.retentionPercentSnapshot);
      _advanceController.text = formNumberText(claim.advanceRecoveryAmount);
      _deductionsController.text = formNumberText(claim.otherDeductions);
      _notesController.text = claim.notes;
      _items
        ..clear()
        ..addAll(detail.items.map(_DraftItem.fromClaimItem));
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
    _retentionController.dispose();
    _advanceController.dispose();
    _deductionsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Form doğrulandıktan SONRA çağrılır: boş olmayan her satır geçerlidir.
  List<ProgressClaimItem> _buildItems() => [
        for (final i in _items)
          if (!i.isBlank)
            ProgressClaimItem(
              id: '',
              subcontractItemId: i.subcontractItemId,
              itemDescription: '',
              itemUnit: '',
              scheduledValue: 0,
              previousProgressAmount: 0,
              currentProgressAmount: parseFormNumber(i.amount)!,
              cumulativeProgressAmount: 0,
              progressPercent: 0,
              remainingAmount: 0,
              sortOrder: 0,
            ),
      ];

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_periodEnd == null) {
      setState(() => _error = 'Dönem sonu tarihi gerekli.');
      return;
    }
    final items = _buildItems();
    if (items.isEmpty) {
      setState(() => _error = 'En az bir geçerli SOV kalemi girin (kalem seçin, tutar >= 0).');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final retention = parseFormPercent(_retentionController.text) ?? 0;
      final advance = parseFormNumber(_advanceController.text) ?? 0;
      final deductions = parseFormNumber(_deductionsController.text) ?? 0;
      final ProgressClaim claim;
      if (widget.isEdit) {
        claim = await repo.updateProgressClaim(
          widget.projectId,
          widget.claimId!,
          periodStart: _fmtDate(_periodStart),
          periodEnd: _fmtDate(_periodEnd)!,
          retentionPercent: retention,
          advanceRecoveryAmount: advance,
          otherDeductions: deductions,
          notes: _notesController.text.trim(),
          items: items,
        );
      } else {
        claim = await repo.createProgressClaim(
          widget.projectId,
          widget.subcontractId,
          periodStart: _fmtDate(_periodStart),
          periodEnd: _fmtDate(_periodEnd)!,
          retentionPercent: retention,
          advanceRecoveryAmount: advance,
          otherDeductions: deductions,
          notes: _notesController.text.trim(),
          items: items,
        );
      }
      final scArgs = (projectId: widget.projectId, subcontractId: widget.subcontractId);
      ref.invalidate(subcontractProgressClaimsProvider(scArgs));
      ref.invalidate(subcontractDetailProvider(scArgs));
      if (widget.isEdit) {
        ref.invalidate(progressClaimDetailProvider((projectId: widget.projectId, claimId: widget.claimId!)));
      }
      if (mounted) {
        leaveSavedForm(
          context,
          '/projeler/${widget.projectId}/taseronlar/${widget.subcontractId}/hakedisler/${claim.id}',
          isEdit: widget.isEdit,
          result: claim,
        );
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scArgs = (projectId: widget.projectId, subcontractId: widget.subcontractId);
    final subcontractAsync = ref.watch(subcontractDetailProvider(scArgs));

    return AppPageScaffold(
      title: Text(widget.isEdit ? 'Hakedişi Düzenle' : 'Yeni Hakediş'),
      body: _loading
          ? const LoadingState()
          : subcontractAsync.when(
              loading: () => const LoadingState(),
              error: (e, _) => ErrorState(error: e, onRetry: () async => ref.invalidate(subcontractDetailProvider(scArgs))),
              data: (sc) => _buildForm(context, sc.items),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<SubcontractItem> subcontractItems) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppFormSection(
            title: 'Dönem Bilgileri',
            children: [
              _DatePickerTile(
                label: 'Dönem Başı (opsiyonel)',
                value: _periodStart,
                onChanged: (d) => setState(() => _periodStart = d),
              ),
              _DatePickerTile(
                label: 'Dönem Sonu',
                value: _periodEnd,
                onChanged: (d) => setState(() => _periodEnd = d),
              ),
            ],
          ),
          AppFormSection(
            title: 'Kesintiler',
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _retentionController,
                      decoration: const InputDecoration(labelText: 'Hakediş Kesintisi %', errorMaxLines: 3),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: formPercentError,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextFormField(
                      controller: _advanceController,
                      decoration: const InputDecoration(labelText: 'Avans Mahsubu (opsiyonel)', errorMaxLines: 3),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) => formNumberError(v, required: false, allowZero: true),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: _deductionsController,
                decoration: const InputDecoration(labelText: 'Diğer Kesintiler (opsiyonel)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) => formNumberError(v, required: false, allowZero: true),
              ),
            ],
          ),
          AppFormSection(
            title: 'Kalemler',
            subtitle: 'SOV kalemi başına bu dönemin ilerleme tutarı',
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
                    subcontractItems: subcontractItems,
                    onChanged: () => setState(() {}),
                    onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
                  )),
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
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Text(_error!, style: AppTypography.error),
            ),
          ],
          PrimaryButton(
            label: widget.isEdit ? 'Kaydet' : 'Hakediş Oluştur',
            loading: _submitting,
            onPressed: _submitting ? null : _submit,
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
      title: Text(label, style: AppTypography.body),
      subtitle: value != null
          ? Text(
              '${value!.day.toString().padLeft(2, '0')}.${value!.month.toString().padLeft(2, '0')}.${value!.year}',
              style: AppTypography.metadata,
            )
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
  const _ItemRow({super.key, required this.item, required this.subcontractItems, required this.onChanged, this.onRemove});

  final _DraftItem item;
  final List<SubcontractItem> subcontractItems;
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
                  initialValue: item.subcontractItemId.isEmpty ? null : item.subcontractItemId,
                  decoration: const InputDecoration(labelText: 'SOV Kalemi', isDense: true),
                  validator: (v) => item.isBlank || (v != null && v.isNotEmpty) ? null : 'SOV kalemi seçin',
                  items: subcontractItems
                      .map((it) => DropdownMenuItem(
                            value: it.id,
                            child: Text(it.description, overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) {
                    item.subcontractItemId = v ?? '';
                    onChanged();
                  },
                ),
              ),
              if (onRemove != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            initialValue: item.amount,
            decoration: const InputDecoration(labelText: 'Bu Dönem İlerleme Tutarı', isDense: true),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (v) => item.isBlank ? null : formNumberError(v, allowZero: true, positiveMessage: 'Negatif olamaz'),
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

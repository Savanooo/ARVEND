import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/widgets/app_buttons.dart';
import '../../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/budget_providers.dart';
import '../../domain/budget.dart';
import '../widgets/budget_ui.dart';

/// Baseline alınmış bütçede bir kalem için revizyon TASLAĞI oluşturur --
/// `POST /budget/adjustments` (projects.budget.manage). Onaylanana kadar
/// revize bütçeyi ETKİLEMEZ. [initialLineId] verilirse kalem sabittir;
/// verilmezse [lines] arasından seçilir. Oluşturulursa true döner.
Future<bool?> showAdjustmentSheet(
  BuildContext context, {
  required String projectId,
  required String currency,
  List<BudgetLine> lines = const [],
  String? initialLineId,
  String? initialLineLabel,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (_) => AdjustmentSheet(
      projectId: projectId,
      currency: currency,
      lines: lines,
      initialLineId: initialLineId,
      initialLineLabel: initialLineLabel,
    ),
  );
}

class AdjustmentSheet extends ConsumerStatefulWidget {
  const AdjustmentSheet({
    super.key,
    required this.projectId,
    required this.currency,
    this.lines = const [],
    this.initialLineId,
    this.initialLineLabel,
  });

  final String projectId;
  final String currency;
  final List<BudgetLine> lines;
  final String? initialLineId;
  final String? initialLineLabel;

  @override
  ConsumerState<AdjustmentSheet> createState() => _AdjustmentSheetState();
}

class _AdjustmentSheetState extends ConsumerState<AdjustmentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  late String? _lineId = widget.initialLineId;
  bool _submitting = false;
  bool _dirty = false;
  String? _error;

  bool get _lineFixed => widget.initialLineId != null;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  String get _title {
    if (_lineFixed) return 'Bütçe Revizyonu — ${widget.initialLineLabel ?? ''}';
    return 'Bütçe Revizyonu';
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final amount = parseTrDecimal(_amount.text, allowNegative: true).value!;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container
          .read(budgetRepositoryProvider)
          .createAdjustment(widget.projectId, budgetLineId: _lineId!, amount: amount, reason: _reason.text.trim());
      invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (isBudgetConflict(e)) invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) setState(() => _error = budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: _submitting,
      dirty: _dirty,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            onChanged: () {
              if (!_dirty) setState(() => _dirty = true);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _title,
                  style: AppTypography.pageTitle.copyWith(fontSize: 17),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.md),
                const BudgetInfoNote(
                  'Bu bütçe baseline alındığı için orijinal tutar değiştirilemez. Bunun yerine bir revizyon '
                  'oluştur; revizyon yalnızca onaylandıktan sonra revize bütçeyi etkiler.',
                ),
                const SizedBox(height: AppSpacing.lg),
                if (!_lineFixed) ...[
                  DropdownButtonFormField<String>(
                    key: const ValueKey('adjustment-line'),
                    initialValue: _lineId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Bütçe Kalemi *'),
                    items: [
                      for (final l in widget.lines)
                        DropdownMenuItem(
                          value: l.id,
                          child: Text(
                            '${l.description} (${l.costCodeCode})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _lineId = v),
                    validator: (v) => v == null ? 'Bütçe kalemi seç' : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                BudgetNumberField(
                  fieldKey: const ValueKey('adjustment-amount'),
                  controller: _amount,
                  label: 'Revizyon Tutarı (${widget.currency})',
                  required: true,
                  allowNegative: true,
                  helperText: 'Azaltmak için negatif gir (ör. -25.000).',
                  extraValidator: (v) => v == 0 ? 'Revizyon tutarı sıfır olamaz' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  key: const ValueKey('adjustment-reason'),
                  controller: _reason,
                  minLines: 2,
                  maxLines: 4,
                  inputFormatters: [LengthLimitingTextInputFormatter(500)],
                  decoration: const InputDecoration(labelText: 'Gerekçe *', alignLabelWithHint: true),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Revizyon gerekçesi zorunludur' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: 'Revizyon Oluştur', loading: _submitting, onPressed: _submit),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).maybePop(),
                  child: const Text('Vazgeç'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

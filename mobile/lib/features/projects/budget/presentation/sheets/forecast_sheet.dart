import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/utils/formatters.dart';
import '../../../../../core/widgets/app_buttons.dart';
import '../../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/budget_providers.dart';
import '../../domain/budget.dart';
import '../widgets/budget_ui.dart';
import '../../../../../core/widgets/app_sheet.dart';

/// Kalem için manuel ETC (kalan tahmini maliyet) girer/düzenler --
/// `PUT /budget/lines/{lineId}/forecast` (projects.cost_control.manage).
/// Kaydedilirse true döner.
Future<bool?> showForecastSheet(
  BuildContext context, {
  required String projectId,
  required String budgetLineId,
  required String lineLabel,
  required String currency,
  CostForecast? existing,
  double? defaultEtc,
}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ForecastSheet(
      projectId: projectId,
      budgetLineId: budgetLineId,
      lineLabel: lineLabel,
      currency: currency,
      existing: existing,
      defaultEtc: defaultEtc,
    ),
  );
}

class ForecastSheet extends ConsumerStatefulWidget {
  const ForecastSheet({
    super.key,
    required this.projectId,
    required this.budgetLineId,
    required this.lineLabel,
    required this.currency,
    this.existing,
    this.defaultEtc,
  });

  final String projectId;
  final String budgetLineId;
  final String lineLabel;
  final String currency;
  final CostForecast? existing;

  /// Sunucunun o anki (varsayılan ya da mevcut) ETC'si -- yalnızca bilgi.
  final double? defaultEtc;

  @override
  ConsumerState<ForecastSheet> createState() => _ForecastSheetState();
}

class _ForecastSheetState extends ConsumerState<ForecastSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _etc = TextEditingController(text: formatTrDecimalInput(widget.existing?.etcAmount));
  late final TextEditingController _note = TextEditingController(text: widget.existing?.note ?? '');
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _etc.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final etc = parseTrDecimal(_etc.text).value ?? 0;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container
          .read(budgetRepositoryProvider)
          .upsertForecast(widget.projectId, widget.budgetLineId, etcAmount: etc, note: _note.text.trim());
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
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.existing == null ? 'Manuel ETC Gir' : 'ETC Tahminini Düzenle',
                  style: AppTypography.pageTitle.copyWith(fontSize: 17),
                ),
                const SizedBox(height: 2),
                Text(widget.lineLabel, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.md),
                const BudgetInfoNote(
                  'ETC (Estimate To Complete), her kalem için "bitirmek üzere kalan tahmini maliyet"tir — girilmezse '
                  'sistem varsayılan olarak (Revize Bütçe − Gerçekleşen, negatif olamaz) önerir. EAC = Gerçekleşen + ETC.',
                ),
                const SizedBox(height: AppSpacing.lg),
                BudgetNumberField(
                  fieldKey: const ValueKey('forecast-etc'),
                  controller: _etc,
                  label: 'ETC (${widget.currency})',
                  required: true,
                  helperText: widget.defaultEtc == null
                      ? null
                      : 'Şu anki ETC: ${Formatters.money(widget.defaultEtc!, currency: widget.currency)}',
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  key: const ValueKey('forecast-note'),
                  controller: _note,
                  minLines: 1,
                  maxLines: 3,
                  inputFormatters: [LengthLimitingTextInputFormatter(500)],
                  decoration: const InputDecoration(labelText: 'Not (opsiyonel)'),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(),
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

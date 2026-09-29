import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'widgets/budget_ui.dart';

/// Yeni Manuel Taahhüt (web `CommitmentsTab` modalı): Bütçe Kalemi
/// (opsiyonel -- seçilirse maliyet kodu o kalemden gelir ve kilitlenir),
/// Maliyet Kodu*, Açıklama*, Tutar*, Tarih*. Çift gönderime karşı formun
/// ömrü boyunca sabit bir `idempotency_key` gönderilir.
/// `projects.cost_control.manage` ister; kaydedilirse `true` ile kapanır.
class CommitmentFormScreen extends ConsumerStatefulWidget {
  const CommitmentFormScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<CommitmentFormScreen> createState() => _CommitmentFormScreenState();
}

class _CommitmentFormScreenState extends ConsumerState<CommitmentFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final String _idempotencyKey = newIdempotencyKey();
  String? _budgetLineId;
  String? _costCodeId;
  late DateTime _date = ref.read(budgetClockProvider)();
  bool _submitting = false;
  bool _dirty = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _dirty = true;
      });
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final input = ManualCommitmentInput(
      costCodeId: _costCodeId!,
      budgetLineId: _budgetLineId,
      description: _description.text.trim(),
      amount: parseTrDecimal(_amount.text).value!,
      committedAt: isoDate(_date),
      idempotencyKey: _idempotencyKey,
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(budgetRepositoryProvider).createCommitment(widget.projectId, input);
      invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) context.pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Yeni Manuel Taahhüt');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (isAuthPending(auth)) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kCostControlManagePermission)) {
      return const AppPageScaffold(
        title: title,
        body: BudgetNoAccessView(
          message: 'Manuel taahhüt girmek için rolünde "Maliyet kontrolünü (WBS/taahhüt/tahmin) yönetme" izni olmalı.',
        ),
      );
    }
    final project = ref.watch(budgetProjectProvider(widget.projectId)).valueOrNull;
    final locked = project != null && isProjectLocked(project.status);
    final canReadBudget = user.can(kBudgetReadPermission);
    final linesAsync = canReadBudget ? ref.watch(budgetLinesProvider(widget.projectId)) : null;
    final costCodesAsync = ref.watch(budgetCostCodesProvider);
    final budget = canReadBudget ? ref.watch(projectBudgetProvider(widget.projectId)).valueOrNull : null;
    final currency = budget?.currency ?? project?.currency ?? 'TRY';

    bool pending(AsyncValue<Object?>? v) => v != null && !v.hasValue && !v.hasError;
    if (pending(linesAsync) || pending(costCodesAsync)) {
      return const AppPageScaffold(title: title, body: LoadingState());
    }
    if (locked) {
      return AppPageScaffold(
        title: title,
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: const [ReadOnlyNotice(kProjectLockedText)],
        ),
      );
    }

    // Bütçe kalemi seçici için izin yoksa (ya da 403) seçici yalnızca
    // "bütçe dışı" seçeneğiyle kalır -- form yine kullanılabilir.
    final lines = linesAsync?.valueOrNull ?? const <BudgetLine>[];
    final selectedLine = lines.where((l) => l.id == _budgetLineId).firstOrNull;

    return UnsavedChangesScope(
      busy: _submitting,
      dirty: _dirty,
      child: AppPageScaffold(
        title: title,
        body: Form(
          key: _formKey,
          onChanged: () {
            if (!_dirty) setState(() => _dirty = true);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              const BudgetInfoNote(
                'Bu, resmi bir satın alma siparişi veya taşeron sözleşmesi değildir — yalnızca sahada bilinen ama '
                'henüz masraf olarak girilmemiş bir maliyet taahhüdünü kayıt altına almak içindir.',
                title: 'Manuel Taahhüt:',
              ),
              const SizedBox(height: AppSpacing.lg),
              AppFormSection(
                title: 'Maliyet Eşlemesi',
                children: [
                  DropdownButtonFormField<String?>(
                    key: const ValueKey('commitment-line'),
                    initialValue: _budgetLineId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Bütçe Kalemi (opsiyonel)'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil (bütçe dışı)')),
                      for (final l in lines)
                        DropdownMenuItem<String?>(
                          value: l.id,
                          child: Text(
                            '${l.description} (${l.costCodeCode})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _budgetLineId = v;
                      final line = lines.where((l) => l.id == v).firstOrNull;
                      if (line != null) _costCodeId = line.costCodeId;
                      _dirty = true;
                    }),
                  ),
                  if (selectedLine != null)
                    _LockedCostCode(label: selectedLine.costCodeLabel)
                  else
                    _costCodeField(costCodesAsync),
                ],
              ),
              AppFormSection(
                title: 'Taahhüt Bilgileri',
                children: [
                  TextFormField(
                    key: const ValueKey('commitment-description'),
                    controller: _description,
                    minLines: 1,
                    maxLines: 3,
                    inputFormatters: [LengthLimitingTextInputFormatter(300)],
                    decoration: const InputDecoration(labelText: 'Açıklama *'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Açıklama zorunludur' : null,
                  ),
                  BudgetNumberField(
                    fieldKey: const ValueKey('commitment-amount'),
                    controller: _amount,
                    label: 'Tutar ($currency)',
                    required: true,
                    extraValidator: (v) => (v != null && v <= 0) ? 'Tutar sıfırdan büyük olmalıdır' : null,
                  ),
                  InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Tarih *',
                        suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                      ),
                      child: Text(Formatters.date(isoDate(_date)), style: AppTypography.body),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
              PrimaryButton(
                label: 'Kaydet',
                loading: _submitting,
                onPressed: (selectedLine == null && costCodesAsync.hasError) ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _costCodeField(AsyncValue<List<OrgCostCode>> costCodesAsync) {
    if (costCodesAsync.hasError) {
      return ReadOnlyNotice(
        isBudgetForbidden(costCodesAsync.error)
            ? kCostCodesForbiddenText
            : 'Maliyet kodları yüklenemedi: ${budgetErrorText(costCodesAsync.error!)}',
      );
    }
    final codes = (costCodesAsync.valueOrNull ?? const <OrgCostCode>[]).where((c) => c.isActive).toList();
    return DropdownButtonFormField<String>(
      key: const ValueKey('commitment-cost-code'),
      initialValue: codes.any((c) => c.id == _costCodeId) ? _costCodeId : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Maliyet Kodu *', hintText: 'Seç…'),
      items: [
        for (final c in codes)
          DropdownMenuItem(
            value: c.id,
            child: Text('${c.code} — ${c.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => setState(() {
        _costCodeId = v;
        _dirty = true;
      }),
      validator: (v) => v == null ? 'Maliyet kodu seç' : null,
    );
  }
}

/// Bütçe kalemi seçildiğinde maliyet kodu o kalemden gelir (web'de seçici
/// devre dışı kalır) -- burada kilitli bir alan olarak gösterilir.
class _LockedCostCode extends StatelessWidget {
  const _LockedCostCode({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Maliyet Kodu',
        enabled: false,
        helperText: 'Seçilen bütçe kaleminin maliyet kodu kullanılır.',
      ),
      child: Text(label, style: AppTypography.body.copyWith(color: AppColors.textMuted)),
    );
  }
}

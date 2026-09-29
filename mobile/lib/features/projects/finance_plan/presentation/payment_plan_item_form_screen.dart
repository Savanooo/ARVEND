import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/projects_providers.dart';
import '../../domain/project.dart';
import '../data/finance_plan_providers.dart';
import '../domain/finance_dates.dart';
import '../domain/payment_plan.dart';
import '../finance_plan_paths.dart';
import 'widgets/finance_plan_ui.dart';

/// Yeni plan kalemi (`/projeler/:id/odeme-plani/yeni`) ve düzenleme
/// (`/projeler/:id/odeme-plani/:itemId/duzenle`). Web formunun alanları
/// (ad, yüzde VEYA tutar, vade) + backend'in kabul ettiği not. Yalnızca
/// `projects.finance.manage` ile açılır; tamamlanmış/iptal edilmiş projede
/// ve iptal edilmiş kalemde form yerine açıklama gösterilir.
class PaymentPlanItemFormScreen extends ConsumerWidget {
  const PaymentPlanItemFormScreen({super.key, required this.projectId, this.itemId});

  final String projectId;

  /// null = yeni kalem.
  final String? itemId;

  bool get isEdit => itemId != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = Text(isEdit ? 'Kalemi Düzenle' : 'Yeni Plan Kalemi');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kFinancePlanManagePermission)) {
      return AppPageScaffold(title: title, body: const NoAccessView(message: kFinanceManageNoAccessText));
    }

    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final planAsync = ref.watch(projectPaymentPlanProvider(projectId));

    Widget errorView(Object e, Future<void> Function() retry) => isFinanceForbidden(e)
        ? const NoAccessView(message: kFinanceManageNoAccessText)
        : ErrorState(error: e, onRetry: retry);

    return AppPageScaffold(
      title: title,
      body: projectAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => errorView(e, () async => ref.invalidate(projectDetailProvider(projectId))),
        data: (project) => planAsync.when(
          loading: () => const LoadingState(),
          error: (e, _) => errorView(e, () async => ref.invalidate(projectPaymentPlanProvider(projectId))),
          data: (plan) {
            if (isFinanceLocked(project)) {
              return NoAccessView(title: 'Proje kilitli', message: financeLockedText(project));
            }
            PaymentPlanItem? existing;
            if (isEdit) {
              for (final i in plan.items) {
                if (i.id == itemId) existing = i;
              }
              if (existing == null) {
                return const EmptyStateView(message: 'Ödeme planı kalemi bulunamadı.');
              }
              if (existing.isCancelled) {
                return const NoAccessView(
                  title: 'Kalem iptal edildi',
                  message: 'İptal edilen ödeme planı kalemi düzenlenemez.',
                );
              }
            }
            return PaymentPlanItemForm(
              project: project,
              existing: existing,
              // Web ile aynı: yeni kalem listenin sonuna eklenir; düzenlemede
              // mevcut sıra korunur (PUT tam güncellemedir).
              sortOrder: existing?.sortOrder ?? plan.items.length,
            );
          },
        ),
      ),
    );
  }
}

enum PlanAmountMode { amount, percentage }

class PaymentPlanItemForm extends ConsumerStatefulWidget {
  const PaymentPlanItemForm({super.key, required this.project, required this.sortOrder, this.existing});

  final Project project;
  final PaymentPlanItem? existing;
  final int sortOrder;

  @override
  ConsumerState<PaymentPlanItemForm> createState() => _PaymentPlanItemFormState();
}

class _PaymentPlanItemFormState extends ConsumerState<PaymentPlanItemForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _percentage;
  late final TextEditingController _notes;
  late PlanAmountMode _mode;
  DateTime? _dueDate;
  late final String _initialSignature;
  bool _saving = false;
  bool _saved = false;

  /// İlk başarısız gönderimden sonra alanlar yazdıkça yeniden doğrulanır
  /// (hata metni düzelince kalkar, tutar önizlemesi görünür).
  bool _autovalidate = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _mode = e?.percentage != null ? PlanAmountMode.percentage : PlanAmountMode.amount;
    _amount = TextEditingController(
      text: e == null || e.percentage != null ? '' : _numberInputText(e.plannedAmount),
    );
    _percentage = TextEditingController(text: e?.percentage == null ? '' : _numberInputText(e!.percentage!));
    _notes = TextEditingController(text: e?.notes ?? '');
    _dueDate = parseApiDate(e?.dueDate);
    _initialSignature = _signature();
    for (final c in [_name, _amount, _percentage, _notes]) {
      c.addListener(_onChanged);
    }
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in [_name, _amount, _percentage, _notes]) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    super.dispose();
  }

  String _signature() => [
        _name.text.trim(),
        _mode.name,
        _amount.text.trim(),
        _percentage.text.trim(),
        _notes.text.trim(),
        _dueDate == null ? '' : apiDate(_dueDate!),
      ].join('|');

  bool get _dirty => !_saved && _signature() != _initialSignature;

  @override
  Widget build(BuildContext context) {
    final currency = widget.project.currency;
    final amount = parseAmountInput(_amount.text);
    final percentage = parsePercentInput(_percentage.text);
    final isEdit = widget.existing != null;

    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _saving,
      child: Form(
        key: _formKey,
        autovalidateMode: _autovalidate ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            AppFormSection(
              title: 'Kalem Bilgileri',
              children: [
                TextFormField(
                  key: const ValueKey('plan-item-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  decoration: const InputDecoration(labelText: 'Kalem Adı *', hintText: 'ör. Peşinat'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Kalem adı zorunludur' : null,
                ),
              ],
            ),
            AppFormSection(
              title: 'Tutar',
              subtitle: 'Tutarı doğrudan gir ya da ana sözleşme bedelinin yüzdesi olarak belirle.',
              children: [
                SegmentedButton<PlanAmountMode>(
                  segments: const [
                    ButtonSegment(value: PlanAmountMode.amount, label: Text('Tutar'), icon: Icon(Icons.payments_outlined)),
                    ButtonSegment(value: PlanAmountMode.percentage, label: Text('Yüzde'), icon: Icon(Icons.percent)),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                if (_mode == PlanAmountMode.amount)
                  TextFormField(
                    key: const ValueKey('plan-item-amount'),
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Planlanan Tutar ($currency) *',
                      helperText: amount != null && amount > 0 ? Formatters.money(amount, currency: currency) : null,
                    ),
                    validator: (v) {
                      final parsed = parseAmountInput(v ?? '');
                      if (parsed == null || parsed <= 0) return 'Tutar sıfırdan büyük olmalıdır';
                      return null;
                    },
                  )
                else
                  TextFormField(
                    key: const ValueKey('plan-item-percentage'),
                    controller: _percentage,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Yüzde (%) *',
                      // Geçerli bir yüzdede hesaplanan tutar önizlenir: "12.5"
                      // gibi bir yazımın ne anlama geldiği kayıttan önce görünür.
                      helperText: percentage != null && percentage > 0 && percentage <= 100
                          ? '= ${Formatters.money(widget.project.contractAmount * percentage / 100, currency: currency)} '
                              '(ana sözleşme bedelinin ${Formatters.percent(percentage)}\'i)'
                          : 'Tutar, ana sözleşme bedeli (${Formatters.money(widget.project.contractAmount, currency: currency)}) '
                              'üzerinden hesaplanır.',
                      helperMaxLines: 2,
                    ),
                    validator: (v) {
                      final parsed = parsePercentInput(v ?? '');
                      if (parsed == null) return 'Geçerli bir yüzde gir (ör. 12,5 ya da 33,33)';
                      if (parsed <= 0) return 'Yüzde sıfırdan büyük olmalıdır';
                      if (parsed > 100) return 'Yüzde en fazla 100 olabilir';
                      return null;
                    },
                  ),
              ],
            ),
            AppFormSection(
              title: 'Vade ve Notlar',
              children: [
                FinanceDateField(
                  label: 'Vade Tarihi',
                  value: _dueDate,
                  helperText: 'Boş bırakılabilir. Vadesi geçen açık kalem "Gecikti" olarak işaretlenir.',
                  onChanged: (d) => setState(() => _dueDate = d),
                ),
                TextFormField(
                  key: const ValueKey('plan-item-notes'),
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Notlar', alignLabelWithHint: true),
                ),
              ],
            ),
            if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
            PrimaryButton(
              label: isEdit ? 'Değişiklikleri Kaydet' : 'Kalemi Ekle',
              loading: _saving,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _autovalidate = true);
      return;
    }
    final byPercentage = _mode == PlanAmountMode.percentage;
    final input = PaymentPlanItemInput(
      name: _name.text,
      percentage: byPercentage ? parsePercentInput(_percentage.text) : null,
      plannedAmount: byPercentage ? null : parseAmountInput(_amount.text),
      dueDate: _dueDate == null ? null : apiDate(_dueDate!),
      sortOrder: widget.sortOrder,
      notes: _notes.text,
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanamaz (UnsavedChangesScope); liste/detay
    // yine de ekrandan bağımsız tazelensin diye kapsayıcı ilk await'ten
    // ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    final projectId = widget.project.id;
    final existing = widget.existing;
    try {
      final repo = container.read(financePlanRepositoryProvider);
      final saved = existing == null
          ? await repo.createPlanItem(projectId, input)
          : await repo.updatePlanItem(projectId, existing.id, input);
      _saved = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(existing == null ? 'Ödeme planı kalemi eklendi.' : 'Ödeme planı kalemi güncellendi.')),
        );
        if (context.canPop()) {
          context.pop(saved);
        } else {
          context.go(paymentPlanPath(projectId));
        }
      }
      invalidatePaymentPlan(container, projectId);
    } catch (e) {
      // 409: proje bu arada tamamlandı/iptal edildi -> proje tazelenir,
      // ekran kilitli görünüme geçer. 404: kalem bu arada iptal edildi.
      if (isFinanceConflict(e)) invalidateFinancePlanProject(container, projectId);
      if (isFinanceNotFound(e)) invalidatePaymentPlan(container, projectId);
      if (mounted) setState(() => _error = financePlanErrorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// Tutar/yüzde alanına ilk değer: tam sayıysa ondalıksız, değilse virgüllü
/// ("250000", "12,5").
String _numberInputText(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  var s = value.toStringAsFixed(2);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  return s.replaceAll('.', ',');
}

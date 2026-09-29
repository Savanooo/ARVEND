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
import '../domain/project_invoice.dart';
import '../finance_plan_paths.dart';
import 'widgets/finance_plan_ui.dart';

/// Yeni fatura (`/projeler/:id/faturalar/yeni`) -- web `InvoicesSection`
/// formunun alanları (no, tip, tarih, tutar) + backend'in kabul ettiği
/// vade, müşteri adı ve not. Fatura "Taslak" başlar; para birimi projenin
/// para birimidir. Kayıttan sonra fatura alanları düzenlenemez (backend'de
/// uç yok), yalnızca durumu değişir. Yalnızca `projects.finance.manage`
/// ile açılır; kilitli projede form yerine açıklama gösterilir.
class InvoiceFormScreen extends ConsumerWidget {
  const InvoiceFormScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const title = Text('Yeni Fatura');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) return const AppPageScaffold(title: title, body: LoadingState());
    if (!user.can(kFinancePlanManagePermission)) {
      return const AppPageScaffold(title: title, body: NoAccessView(message: kFinanceManageNoAccessText));
    }
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    return AppPageScaffold(
      title: title,
      body: projectAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isFinanceForbidden(e)
            ? const NoAccessView(message: kFinanceManageNoAccessText)
            : ErrorState(error: e, onRetry: () async => ref.invalidate(projectDetailProvider(projectId))),
        data: (project) => isFinanceLocked(project)
            ? NoAccessView(title: 'Proje kilitli', message: financeLockedText(project))
            : InvoiceForm(project: project),
      ),
    );
  }
}

class InvoiceForm extends ConsumerStatefulWidget {
  const InvoiceForm({super.key, required this.project});

  final Project project;

  @override
  ConsumerState<InvoiceForm> createState() => _InvoiceFormState();
}

class _InvoiceFormState extends ConsumerState<InvoiceForm> {
  final _formKey = GlobalKey<FormState>();
  final _invoiceNo = TextEditingController();
  final _amount = TextEditingController();
  final _customerName = TextEditingController();
  final _notes = TextEditingController();
  String _type = kInvoiceTypeSales;
  late DateTime _invoiceDate;
  late final DateTime _initialInvoiceDate;
  DateTime? _dueDate;
  String? _dueDateError;
  bool _saving = false;
  bool _saved = false;

  /// İlk başarısız gönderimden sonra alanlar yazdıkça yeniden doğrulanır
  /// (hata metni düzelince kalkar, tutar önizlemesi görünür).
  bool _autovalidate = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Web ile aynı: fatura tarihi varsayılanı bugün (İstanbul günü).
    _invoiceDate = ref.read(financePlanTodayProvider);
    _initialInvoiceDate = _invoiceDate;
    for (final c in [_invoiceNo, _amount, _customerName, _notes]) {
      c.addListener(_onChanged);
    }
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in [_invoiceNo, _amount, _customerName, _notes]) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    super.dispose();
  }

  bool get _dirty =>
      !_saved &&
      (_invoiceNo.text.trim().isNotEmpty ||
          _amount.text.trim().isNotEmpty ||
          _customerName.text.trim().isNotEmpty ||
          _notes.text.trim().isNotEmpty ||
          _type != kInvoiceTypeSales ||
          _dueDate != null ||
          _invoiceDate != _initialInvoiceDate);

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final currency = project.currency;
    final amount = parseAmountInput(_amount.text);
    final isPurchase = _type == kInvoiceTypePurchase;

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
              title: 'Fatura Bilgileri',
              children: [
                SegmentedButton<String>(
                  segments: [
                    for (final e in kInvoiceTypeLabels.entries) ButtonSegment(value: e.key, label: Text(e.value)),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
                TextFormField(
                  key: const ValueKey('invoice-no'),
                  controller: _invoiceNo,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [LengthLimitingTextInputFormatter(100)],
                  decoration: const InputDecoration(labelText: 'Fatura No *', hintText: 'ör. ARV2026000123'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Fatura numarası zorunludur' : null,
                ),
                FinanceDateField(
                  label: 'Fatura Tarihi *',
                  value: _invoiceDate,
                  clearable: false,
                  onChanged: (d) => setState(() => _invoiceDate = d ?? _invoiceDate),
                ),
                FinanceDateField(
                  label: 'Vade Tarihi',
                  value: _dueDate,
                  errorText: _dueDateError,
                  helperText: 'Boş bırakılabilir.',
                  onChanged: (d) => setState(() {
                    _dueDate = d;
                    _dueDateError = null;
                  }),
                ),
              ],
            ),
            AppFormSection(
              title: 'Tutar',
              children: [
                TextFormField(
                  key: const ValueKey('invoice-amount'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Tutar ($currency) *',
                    helperText: amount != null && amount > 0
                        ? Formatters.money(amount, currency: currency)
                        : 'Fatura projenin para biriminde ($currency) kaydedilir.',
                    helperMaxLines: 2,
                  ),
                  validator: (v) {
                    final parsed = parseAmountInput(v ?? '');
                    if (parsed == null || parsed <= 0) return 'Tutar sıfırdan büyük olmalıdır';
                    return null;
                  },
                ),
              ],
            ),
            AppFormSection(
              title: isPurchase ? 'Tedarikçi ve Notlar' : 'Müşteri ve Notlar',
              children: [
                // Alış faturasında karşı taraf TEDARİKÇİDİR ve zorunludur:
                // backend boş adı proje MÜŞTERİSİYLE doldurur -- boş bırakılan
                // bir alış faturası müşteriyi tedarikçi olarak kaydederdi.
                TextFormField(
                  key: const ValueKey('invoice-customer'),
                  controller: _customerName,
                  textCapitalization: TextCapitalization.words,
                  decoration: isPurchase
                      ? const InputDecoration(
                          labelText: 'Tedarikçi / Firma *',
                          helperText: 'Faturayı kesen tedarikçi.',
                        )
                      : InputDecoration(
                          labelText: 'Müşteri / Firma',
                          hintText: project.customerName.isEmpty ? null : project.customerName,
                          helperText: project.customerName.isEmpty
                              ? 'Boş bırakılırsa proje müşterisi yazılır.'
                              : 'Boş bırakılırsa proje müşterisi (${project.customerName}) yazılır.',
                          helperMaxLines: 2,
                        ),
                  validator: (v) =>
                      isPurchase && (v == null || v.trim().isEmpty) ? 'Tedarikçi adı zorunludur' : null,
                ),
                TextFormField(
                  key: const ValueKey('invoice-notes'),
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Notlar', alignLabelWithHint: true),
                ),
              ],
            ),
            const Text(
              'Fatura "Taslak" olarak kaydedilir; durumunu fatura detayından değiştirebilirsin. Kayıttan sonra '
              'fatura bilgileri değiştirilemez.',
              style: AppTypography.helper,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
            PrimaryButton(label: 'Faturayı Kaydet', loading: _saving, onPressed: _submit),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final fieldsOk = _formKey.currentState?.validate() ?? false;
    final due = _dueDate;
    final dueError = due != null && due.isBefore(_invoiceDate) ? 'Vade tarihi fatura tarihinden önce olamaz' : null;
    setState(() {
      _dueDateError = dueError;
      if (!fieldsOk) _autovalidate = true;
    });
    if (!fieldsOk || dueError != null) return;
    final project = widget.project;
    final input = InvoiceInput(
      invoiceNo: _invoiceNo.text,
      invoiceType: _type,
      invoiceDate: apiDate(_invoiceDate),
      dueDate: due == null ? null : apiDate(due),
      amount: parseAmountInput(_amount.text)!,
      currency: project.currency,
      customerName: _customerName.text,
      notes: _notes.text,
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final saved = await container.read(financePlanRepositoryProvider).createInvoice(project.id, input);
      _saved = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${saved.invoiceNo}" faturası eklendi.')));
        if (context.canPop()) {
          context.pop(saved);
        } else {
          context.go(invoicesPath(project.id));
        }
      }
      invalidateInvoices(container, project.id);
    } catch (e) {
      if (isFinanceConflict(e)) invalidateFinancePlanProject(container, project.id);
      if (mounted) setState(() => _error = financePlanErrorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../budget/data/budget_providers.dart';
import '../budget/domain/budget.dart' show kBudgetReadPermission, kCostCodesReadPermission;
import '../data/projects_providers.dart';
import '../domain/project.dart';
import '../finance_plan/domain/finance_dates.dart' show parseAmountInput;

/// "Masraf Ekle" (web ExpensesSection formu). Kategori/açıklama/tutar/tarih/
/// tedarikçi/fatura no'nun yanında web'deki opsiyonel bağlar: Ek İş, Bütçe
/// Kalemi (seçilince maliyet kodu ondan gelir) ve Maliyet Kodu + Not.
/// Taşeron ödemeleri buraya girilmez (çift sayım) -- Taşeron Ödemeleri'nden.
Future<Expense?> showExpenseFormSheet(BuildContext context, String projectId, {required String currency}) {
  return showModalBottomSheet<Expense>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Kayıt sürerken sayfa kapanamaz (UnsavedChangesScope + sürükleme
    // kapalı; sürükleyerek kapatma PopScope'u atlar): kapanırsa kayıt oluşur
    // ama çağıran sonucu alamaz, liste tazelenmezdi.
    enableDrag: false,
    builder: (context) => _ExpenseFormSheet(projectId: projectId, currency: currency),
  );
}

class _ExpenseFormSheet extends ConsumerStatefulWidget {
  const _ExpenseFormSheet({required this.projectId, required this.currency});
  final String projectId;
  final String currency;

  @override
  ConsumerState<_ExpenseFormSheet> createState() => _ExpenseFormSheetState();
}

class _ExpenseFormSheetState extends ConsumerState<_ExpenseFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController();
  final _supplierController = TextEditingController();
  final _invoiceController = TextEditingController();
  final _notesController = TextEditingController();
  String _category = 'material';
  DateTime _date = DateTime.now();
  String? _changeOrderId;
  String? _budgetLineId;
  String? _costCodeId;
  bool _submitting = false;
  String? _error;

  /// Form örneği başına SABİT anahtar -- ağ hatası sonrası yeniden deneme
  /// mükerrer masraf oluşturmaz (web ile aynı).
  final _idempotencyKey = 'exp-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    _supplierController.dispose();
    _invoiceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final expense = await ref
          .read(projectsRepositoryProvider)
          .createExpense(
            widget.projectId,
            category: _category,
            description: _descriptionController.text.trim(),
            // Türkçe giriş: "64.000" = altmış dört bin, "1.250,50" kabul edilir.
            amount: parseAmountInput(_amountController.text)!,
            currency: widget.currency,
            expenseDate:
                '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
            supplierName: _supplierController.text.trim(),
            invoiceNo: _invoiceController.text.trim(),
            notes: _notesController.text.trim(),
            changeOrderId: _changeOrderId ?? '',
            budgetLineId: _budgetLineId ?? '',
            costCodeId: _costCodeId ?? '',
            idempotencyKey: _idempotencyKey,
          );
      if (mounted) Navigator.of(context).pop(expense);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Seçiciler yalnızca oturum bilinen ve ilgili OKUMA iznine sahip kişide
    // yüklenir (gereksiz 403 yok); liste boşsa ya da yüklenemezse alan hiç
    // görünmez, masraf formu yine çalışır (web ile aynı).
    final user = ref.watch(authControllerProvider).valueOrNull;
    bool allowed(String code) => user != null && user.can(code);

    final changeOrders = allowed('projects.finance.read')
        ? (ref.watch(projectChangeOrdersProvider(widget.projectId)).valueOrNull ?? const <ChangeOrder>[])
              // İptal edilmiş/yerine yenisi gelmiş ek işe bağlamak anlamsız.
              .where((co) => co.status != 'cancelled' && co.status != 'superseded')
              .toList()
        : const <ChangeOrder>[];
    final budgetLines = allowed(kBudgetReadPermission)
        ? (ref.watch(budgetLinesProvider(widget.projectId)).valueOrNull ?? const [])
        : const [];
    final costCodes = allowed(kCostCodesReadPermission)
        ? (ref.watch(orgCostCodesProvider).valueOrNull ?? const []).where((c) => c.isActive).toList()
        : const [];

    return UnsavedChangesScope(
      busy: _submitting,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Masraf Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Masraf Bilgileri',
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'Kategori'),
                      items: expenseCategories.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) => setState(() => _category = v!),
                    ),
                    TextFormField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(labelText: 'Açıklama'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Açıklama gerekli' : null,
                    ),
                    TextFormField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Tutar (${widget.currency})'),
                      validator: (v) {
                        final parsed = parseAmountInput(v ?? '');
                        if (parsed == null || parsed <= 0) return 'Geçerli bir tutar girin';
                        return null;
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Tarih'),
                      subtitle: Text(
                        '${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}',
                      ),
                      trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                    ),
                    TextFormField(
                      controller: _supplierController,
                      decoration: const InputDecoration(labelText: 'Tedarikçi (opsiyonel)'),
                    ),
                    TextFormField(
                      controller: _invoiceController,
                      decoration: const InputDecoration(labelText: 'Fatura No (opsiyonel)'),
                    ),
                  ],
                ),
                if (changeOrders.isNotEmpty || budgetLines.isNotEmpty || costCodes.isNotEmpty)
                  AppFormSection(
                    title: 'Bağlantılar (opsiyonel)',
                    children: [
                      if (changeOrders.isNotEmpty)
                        DropdownButtonFormField<String?>(
                          key: const ValueKey('masraf-ek-is'),
                          initialValue: _changeOrderId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Ek İş (opsiyonel)'),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil')),
                            for (final co in changeOrders)
                              DropdownMenuItem<String?>(
                                value: co.id,
                                child: Text(
                                  '${co.changeOrderNo} · ${co.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _changeOrderId = v),
                        ),
                      if (budgetLines.isNotEmpty)
                        DropdownButtonFormField<String?>(
                          key: const ValueKey('masraf-butce-kalemi'),
                          initialValue: _budgetLineId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Bütçe Kalemi (opsiyonel)'),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil (bütçe dışı)')),
                            for (final line in budgetLines)
                              DropdownMenuItem<String?>(
                                value: line.id,
                                child: Text(
                                  line.costCodeCode.isEmpty
                                      ? line.description
                                      : '${line.description} (${line.costCodeCode})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          // Maliyet kodu seçilen bütçe kaleminden OTOMATİK gelir
                          // (sunucu da aynı kuralı uygular).
                          onChanged: (v) => setState(() {
                            _budgetLineId = v;
                            if (v != null) {
                              _costCodeId = budgetLines.firstWhere((l) => l.id == v).costCodeId;
                            }
                          }),
                        ),
                      if (costCodes.isNotEmpty)
                        DropdownButtonFormField<String?>(
                          // Bütçe kalemi değişince kalemin koduyla yeniden kurulur.
                          key: ValueKey('masraf-maliyet-kodu-$_budgetLineId'),
                          initialValue: costCodes.any((c) => c.id == _costCodeId) ? _costCodeId : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Maliyet Kodu (opsiyonel)',
                            helperText: _budgetLineId != null ? 'Bütçe kaleminden gelir.' : null,
                          ),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Yok')),
                            for (final c in costCodes)
                              DropdownMenuItem<String?>(
                                value: c.id,
                                child: Text('${c.code} — ${c.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: _budgetLineId != null ? null : (v) => setState(() => _costCodeId = v),
                        ),
                    ],
                  ),
                AppFormSection(
                  title: 'Not',
                  children: [
                    TextFormField(
                      controller: _notesController,
                      minLines: 2,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(labelText: 'Not (opsiyonel)', alignLabelWithHint: true),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

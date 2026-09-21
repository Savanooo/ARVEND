import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

Future<Expense?> showExpenseFormSheet(BuildContext context, String projectId, {required String currency}) {
  return showModalBottomSheet<Expense>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
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
  String _category = 'material';
  DateTime _date = DateTime.now();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    _supplierController.dispose();
    _invoiceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final expense = await ref.read(projectsRepositoryProvider).createExpense(
            widget.projectId,
            category: _category,
            description: _descriptionController.text.trim(),
            amount: double.parse(_amountController.text.replaceAll(',', '.')),
            expenseDate: '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
            supplierName: _supplierController.text.trim(),
            invoiceNo: _invoiceController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(expense);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                      final parsed = double.tryParse((v ?? '').replaceAll(',', '.'));
                      if (parsed == null || parsed <= 0) return 'Geçerli bir tutar girin';
                      return null;
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Tarih'),
                    subtitle: Text(
                        '${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}'),
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
              if (_error != null) ...[
                Text(_error!, style: AppTypography.error),
                const SizedBox(height: AppSpacing.md),
              ],
              PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

Future<Collection?> showCollectionFormSheet(BuildContext context, String projectId, {required String currency}) {
  return showModalBottomSheet<Collection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _CollectionFormSheet(projectId: projectId, currency: currency),
  );
}

class _CollectionFormSheet extends ConsumerStatefulWidget {
  const _CollectionFormSheet({required this.projectId, required this.currency});
  final String projectId;
  final String currency;

  @override
  ConsumerState<_CollectionFormSheet> createState() => _CollectionFormSheetState();
}

class _CollectionFormSheetState extends ConsumerState<_CollectionFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _paymentMethodController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _referenceController = TextEditingController();
  DateTime _date = DateTime.now();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amountController.dispose();
    _paymentMethodController.dispose();
    _descriptionController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final collection = await ref.read(projectsRepositoryProvider).createCollection(
            widget.projectId,
            amount: double.parse(_amountController.text.replaceAll(',', '.')),
            receivedDate:
                '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
            paymentMethod: _paymentMethodController.text.trim(),
            description: _descriptionController.text.trim(),
            referenceNo: _referenceController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(collection);
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
              Text('Tahsilat Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
              const SizedBox(height: AppSpacing.lg),
              AppFormSection(
                title: 'Tahsilat Bilgileri',
                children: [
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
                    controller: _paymentMethodController,
                    decoration: const InputDecoration(labelText: 'Ödeme Yöntemi (opsiyonel)'),
                  ),
                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
                  ),
                  TextFormField(
                    controller: _referenceController,
                    decoration: const InputDecoration(labelText: 'Referans No (opsiyonel)'),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';
import 'form_number_input.dart';

Future<SubcontractPayment?> showSubcontractPaymentFormSheet(
  BuildContext context,
  String projectId,
  String subcontractId, {
  required String currency,
}) {
  return showModalBottomSheet<SubcontractPayment>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _SubcontractPaymentFormSheet(
      projectId: projectId,
      subcontractId: subcontractId,
      currency: currency,
    ),
  );
}

class _SubcontractPaymentFormSheet extends ConsumerStatefulWidget {
  const _SubcontractPaymentFormSheet({
    required this.projectId,
    required this.subcontractId,
    required this.currency,
  });
  final String projectId;
  final String subcontractId;
  final String currency;

  @override
  ConsumerState<_SubcontractPaymentFormSheet> createState() => _SubcontractPaymentFormSheetState();
}

class _SubcontractPaymentFormSheetState extends ConsumerState<_SubcontractPaymentFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _paymentMethodController = TextEditingController();
  final _referenceController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime _date = DateTime.now();
  bool _submitting = false;
  String? _error;

  /// Form örneği başına SABİT anahtar (masraf/tahsilat formlarıyla aynı
  /// desen): yanıtı kaybolan bir kaydı yeniden denemek ikinci bir ödeme
  /// oluşturmaz -- sunucu aynı anahtarlı ödemeyi döndürür. Anahtar taşeron
  /// sözleşmesine özgüdür (sunucu da sözleşme bazında eşler).
  late final _idempotencyKey = 'scpay-${widget.subcontractId}-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void dispose() {
    _amountController.dispose();
    _paymentMethodController.dispose();
    _referenceController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final payment = await ref.read(projectsRepositoryProvider).createSubcontractPayment(
            widget.projectId,
            widget.subcontractId,
            // Türkçe giriş: "1.250" = bin iki yüz elli, "1.250,50" kabul edilir.
            amount: parseFormNumber(_amountController.text)!,
            paidDate:
                '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
            paymentMethod: _paymentMethodController.text.trim(),
            referenceNo: _referenceController.text.trim(),
            description: _descriptionController.text.trim(),
            idempotencyKey: _idempotencyKey,
          );
      if (mounted) Navigator.of(context).pop(payment);
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
              Text('Taşeron Ödemesi Kaydet', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
              const SizedBox(height: 2),
              // Ödeme, GERÇEK bir nakit çıkışıdır -- hakedişin (ProgressClaim)
              // sertifikasyonu İLE KARIŞTIRILMAMALI (bkz. domain/
              // subcontract.dart `SubcontractPayment` dosya başı notu).
              Text(
                'Gerçek bir nakit çıkışını kaydeder -- hakediş sertifikasyonundan ayrıdır.',
                style: AppTypography.helper,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Ödenen Tutar (${widget.currency})'),
                validator: (v) => formNumberError(
                  v,
                  requiredMessage: 'Geçerli bir tutar girin',
                  positiveMessage: 'Geçerli bir tutar girin',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ödeme Tarihi'),
                subtitle:
                    Text('${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}'),
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
              const SizedBox(height: AppSpacing.xs),
              TextFormField(
                controller: _paymentMethodController,
                decoration: const InputDecoration(labelText: 'Ödeme Yöntemi (opsiyonel)'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _referenceController,
                decoration: const InputDecoration(labelText: 'Referans No (opsiyonel)'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(_error!, style: AppTypography.error),
              ],
              const SizedBox(height: AppSpacing.xl),
              PrimaryButton(
                label: 'Kaydet',
                loading: _submitting,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

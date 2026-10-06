import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
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

  /// Ödemenin karşılığı olan SERTİFİKALI hakediş (opsiyonel -- avans/
  /// mobilizasyon ödemesi hiçbir hakedişe bağlanmaz). Eskiden hiç
  /// gönderilmiyordu; hakediş detayındaki "Bu Hakedişe Karşı Ödenen" bu
  /// yüzden hep 0 kalıyordu.
  String? _progressClaimId;
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
            progressClaimId: _progressClaimId,
            idempotencyKey: _idempotencyKey,
          );
      if (mounted) Navigator.of(context).pop(payment);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _claimHelper(ProgressClaim claim, List<SubcontractPayment>? payments) {
    final net = 'Net hakediş ${Formatters.money(claim.netPayable, currency: widget.currency)}';
    if (payments == null) return net;
    final paid = paidAgainstClaim(payments, claim.id);
    final remaining = claimUnpaidRemainder(claim, payments);
    return '$net · ödenen ${Formatters.money(paid, currency: widget.currency)} · '
        'kalan ${Formatters.money(remaining, currency: widget.currency)}';
  }

  @override
  Widget build(BuildContext context) {
    // Hakediş seçici yalnızca oturum bilinen ve hakediş OKUMA iznine sahip
    // kişide yüklenir (gereksiz 403 yok); sertifikalı hakediş yoksa ya da
    // liste yüklenemezse alan hiç görünmez, ödeme yine kaydedilir.
    final user = ref.watch(authControllerProvider).valueOrNull;
    final args = (projectId: widget.projectId, subcontractId: widget.subcontractId);
    final claims = user != null && user.can('projects.subcontract_claims.read')
        ? (ref.watch(subcontractProgressClaimsProvider(args)).valueOrNull ?? const <ProgressClaim>[])
            .where((c) => c.isPayable)
            .toList()
        : const <ProgressClaim>[];
    // Seçili hakedişin kalanı (ödeme listesi okunabiliyorsa) -- yanlış
    // hakedişe ya da fazla ödeme kaydetmeden önce görünsün.
    final payments = user != null && user.can('projects.subcontract_payments.read')
        ? ref.watch(subcontractPaymentsProvider(args)).valueOrNull
        : null;
    final selectedClaim = claims.where((c) => c.id == _progressClaimId).firstOrNull;

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
              if (claims.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String?>(
                  key: const ValueKey('taseron-odeme-hakedis'),
                  initialValue: _progressClaimId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Hakediş (opsiyonel)',
                    helperText: selectedClaim == null
                        ? 'Bu ödeme bir hakedişin karşılığıysa seçin.'
                        : _claimHelper(selectedClaim, payments),
                    helperMaxLines: 3,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil (avans vb.)')),
                    for (final c in claims)
                      DropdownMenuItem<String?>(
                        value: c.id,
                        child: Text(
                          '${c.claimNumber} · net ${Formatters.money(c.netPayable, currency: widget.currency)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _progressClaimId = v),
                ),
              ],
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

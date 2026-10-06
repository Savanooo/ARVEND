import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';
import '../finance_plan/domain/finance_dates.dart' show parseAmountInput;
import '../finance_plan/data/finance_plan_providers.dart';
import 'form_project_banner.dart';
import '../../../core/widgets/app_sheet.dart';

/// "Tahsilat Ekle" (web CollectionsSection formu). [initialPlanItemId]
/// verilirse tahsilat o ödeme planı kalemine bağlı başlar.
Future<Collection?> showCollectionFormSheet(
  BuildContext context,
  String projectId, {
  required String currency,
  String? initialPlanItemId,
  String? projectLabel,
}) {
  return showAppSheet<Collection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        _CollectionFormSheet(
          projectId: projectId,
          currency: currency,
          initialPlanItemId: initialPlanItemId,
          projectLabel: projectLabel,
        ),
  );
}

class _CollectionFormSheet extends ConsumerStatefulWidget {
  const _CollectionFormSheet({
    required this.projectId,
    required this.currency,
    this.initialPlanItemId,
    this.projectLabel,
  });
  final String projectId;
  final String currency;
  final String? initialPlanItemId;
  final String? projectLabel;

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
  late String? _planItemId = widget.initialPlanItemId;
  bool _submitting = false;
  String? _error;

  /// Form örneği başına SABİT anahtar (web ile aynı): yanıtı ağda kaybolan
  /// bir kaydın yeniden denemesi aynı anahtarla gider, mükerrer tahsilat
  /// oluşmaz. Yalnızca kayıt kesinleşince form kapanır.
  final _idempotencyKey = 'col-${DateTime.now().microsecondsSinceEpoch}';

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
      final collection = await ref
          .read(projectsRepositoryProvider)
          .createCollection(
            widget.projectId,
            // Türkçe giriş: "64.000" = altmış dört bin, "1.250,50" kabul edilir.
            amount: parseAmountInput(_amountController.text)!,
            receivedDate:
                '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
            paymentMethod: _paymentMethodController.text.trim(),
            description: _descriptionController.text.trim(),
            referenceNo: _referenceController.text.trim(),
            paymentPlanItemId: _planItemId,
            idempotencyKey: _idempotencyKey,
          );
      if (mounted) Navigator.of(context).pop(collection);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ödeme planı seçicisi yalnızca oturum bilinen ve finans okuma izni olan
    // kişide yüklenir (sheet zaten finance.manage ile açılır); plan yoksa ya
    // da yüklenemezse alan hiç görünmez, form yine çalışır.
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canReadPlan = user != null && user.can('projects.finance.read');
    final planItems = canReadPlan
        ? (ref.watch(projectPaymentPlanProvider(widget.projectId)).valueOrNull?.items ?? const [])
              .where((i) => !i.isCancelled)
              .toList()
        : const [];
    final selectedPlanItem = planItems.any((i) => i.id == _planItemId) ? _planItemId : null;

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
                Text('Tahsilat Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                if (widget.projectLabel case final label?) ...[
                  const SizedBox(height: AppSpacing.md),
                  FormProjectBanner(label: label),
                ],
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Tahsilat Bilgileri',
                  children: [
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
                    if (planItems.isNotEmpty)
                      DropdownButtonFormField<String?>(
                        key: const ValueKey('tahsilat-plan-kalemi'),
                        initialValue: selectedPlanItem,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Ödeme Planı Kalemi (opsiyonel)'),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil')),
                          for (final item in planItems)
                            DropdownMenuItem<String?>(
                              value: item.id,
                              child: Text(
                                '${item.name} · kalan ${Formatters.money(item.remainingAmount, currency: widget.currency)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _planItemId = v),
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
      ),
    );
  }
}

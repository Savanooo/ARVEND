import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../../projects/budget/domain/budget.dart' show formatTrDecimalInput, parseTrDecimal;
import '../data/payroll_providers.dart';
import '../domain/payroll.dart';
import '../../../core/widgets/app_sheet.dart';

const _paymentTypeTones = {
  'maaş': ('Maaş', StatusTone.success),
  'avans': ('Avans', StatusTone.gold),
  'mesai': ('Mesai', StatusTone.gold),
  'prim': ('Prim', StatusTone.success),
  'diğer': ('Diğer', StatusTone.muted),
};

/// Kalandan düşülmeyen türler -- backend PayrollSummaryByPeriod ile aynı küme.
const _extraTypes = {'prim', 'diğer'};

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Personel satırının maaş durumu. "Ödendi" yalnızca hakediş gerçekten
/// ödenmişse: hiç çalışmamış ve ödeme almamış kişi ("Çalışma yok") ya da
/// hakedişini aşan avans alan kişi ("Fazla ödendi") eskiden de "Ödendi"
/// görünüyordu.
(String, StatusTone) payrollStatus(PayrollSummaryRow row) {
  if (!row.hasWage) return ('Ücret tanımsız', StatusTone.muted);
  if (row.isWaiting) return ('Bekliyor', StatusTone.gold);
  if (row.remaining < 0) return ('Fazla ödendi', StatusTone.info);
  if (row.earned == 0 && row.paidTotal == 0) return ('Çalışma yok', StatusTone.muted);
  return ('Ödendi', StatusTone.success);
}

/// Ödeme formunu açar. [payFor] + tür 'maaş' (kişinin "Öde"si): personel
/// seçili, tutar = kalan. Avansta tutar önerilmez -- kalan, avansın tutarı
/// değildir.
Future<void> showPaymentForm(
  BuildContext context, {
  required List<PayrollSummaryRow> employees,
  required String month,
  required VoidCallback onSaved,
  PayrollSummaryRow? payFor,
  String type = 'maaş',
}) {
  return showAppSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => PaymentFormSheet(
      employees: employees,
      initialPeriod: month,
      initialEmployeeId: payFor?.employeeId,
      initialAmount: type == 'avans' ? null : payFor?.remaining,
      initialType: type,
      onSaved: onSaved,
    ),
  );
}

/// Ödeme silme onayı. Para kaydı: kime, ne kadar, hangi tür -- yanlış
/// satıra dokunup başka bir ödemeyi silmek kolay (web ile aynı onay metni).
Future<void> confirmDeletePayment(
  BuildContext context,
  WidgetRef ref,
  SalaryPayment p, {
  required VoidCallback onDeleted,
}) async {
  final who = p.employeeName.isEmpty ? 'personel' : p.employeeName;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ödeme silinsin mi?'),
      content: Text('$who — ${Formatters.money(p.amount)} (${p.paymentType})\n${Formatters.longDate(p.paidDate)}'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Vazgeç')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Sil'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(payrollRepositoryProvider).delete(p.id);
    onDeleted();
  } on ApiException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Tek bir ödeme satırı (tarih, açıklama, tür rozeti, tutar).
class PaymentCard extends StatelessWidget {
  const PaymentCard({super.key, required this.payment, this.onTap, this.showName = true});

  final SalaryPayment payment;
  final VoidCallback? onTap;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final p = payment;
    return AppListCard(
      onTap: onTap,
      title: showName ? (p.employeeName.isEmpty ? p.employeeId : p.employeeName) : Formatters.longDate(p.paidDate),
      subtitle: [
        if (showName) Formatters.longDate(p.paidDate),
        if (p.description.isNotEmpty) p.description,
      ].join('  ·  '),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusRegistry.build(p.paymentType, _paymentTypeTones),
          const SizedBox(height: AppSpacing.xs),
          MoneyText(p.amount, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Ödeme ekleme formu. Herkese açık değil: çağıran yalnızca payroll.manage
/// varsa açar (backend de ayrıca zorlar).
class PaymentFormSheet extends ConsumerStatefulWidget {
  const PaymentFormSheet({
    super.key,
    required this.employees,
    required this.initialPeriod,
    required this.onSaved,
    this.initialEmployeeId,
    this.initialAmount,
    this.initialType = 'maaş',
  });

  final List<PayrollSummaryRow> employees;
  final String initialPeriod;
  final VoidCallback onSaved;
  final String? initialEmployeeId;
  final double? initialAmount;
  final String initialType;

  @override
  ConsumerState<PaymentFormSheet> createState() => _PaymentFormSheetState();
}

class _PaymentFormSheetState extends ConsumerState<PaymentFormSheet> {
  String? _employeeId;
  late String _type = kPaymentTypes.contains(widget.initialType) ? widget.initialType : 'maaş';
  DateTime _paidDate = DateTime.now();
  late final TextEditingController _amountController;
  late final TextEditingController _periodController;
  late final TextEditingController _descriptionController;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final preselected = widget.employees.any((e) => e.employeeId == widget.initialEmployeeId);
    _employeeId = preselected
        ? widget.initialEmployeeId
        : (widget.employees.isEmpty ? null : widget.employees.first.employeeId);
    final amount = widget.initialAmount;
    _amountController = TextEditingController(
      text: preselected && amount != null && amount > 0 ? formatTrDecimalInput(amount) : '',
    );
    _periodController = TextEditingController(text: widget.initialPeriod);
    _descriptionController = TextEditingController();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _periodController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Seçili personelin bu ayki kalanı -- yalnızca form tablodaki ayla aynı
  /// aya yazıyorsa ve ücret tanımlıysa (başka ayın kalanı bilinmiyor).
  String? get _remainingHint {
    if (_periodController.text.trim() != widget.initialPeriod) return null;
    final row = widget.employees.where((e) => e.employeeId == _employeeId).firstOrNull;
    if (row == null || !row.hasWage) return null;
    final rest = row.remaining > 0
        ? 'Kalan: ${Formatters.money(row.remaining)}'
        : row.remaining < 0
        ? 'Kalan yok (${Formatters.money(-row.remaining)} fazla ödendi)'
        : 'Kalan yok';
    if (_extraTypes.contains(_type)) return '$rest · Prim ve diğer kalandan düşmez.';
    if (_type == 'avans') return '$rest · Avans bu ayın maaşından düşülür.';
    return '$rest · Fazla ödeme sonraki aya devreder.';
  }

  @override
  Widget build(BuildContext context) {
    final hint = _remainingHint;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_type == 'avans' ? 'Avans Ver' : 'Ödeme Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.lg),
            if (widget.employees.isEmpty)
              Text('Önce aktif personel eklemelisiniz.', style: AppTypography.error)
            else
              DropdownButtonFormField<String>(
                initialValue: _employeeId,
                // Uzun ad + "(pasif)" dar ekranda satırı taşırmasın.
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Personel'),
                items: widget.employees
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.employeeId,
                        child: Text(
                          e.isActive ? e.fullName : '${e.fullName} (pasif)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _employeeId = v),
              ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Tür'),
              items: kPaymentTypes
                  .map((t) => DropdownMenuItem(value: t, child: Text(_paymentTypeTones[t]!.$1)))
                  .toList(),
              onChanged: (v) => setState(() => _type = v!),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('payment-amount'),
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Tutar (₺)',
                hintText: 'ör. 25.000 veya 1250,50',
                helperText: hint,
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('payment-period'),
              controller: _periodController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Ait olduğu ay (YYYY-AA)'),
            ),
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ödeme tarihi'),
              subtitle: Text(Formatters.longDate(_isoDay(_paidDate))),
              trailing: const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.textMuted),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _paidDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _paidDate = picked);
              },
            ),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
              maxLines: 2,
            ),
            if (_error != null) ...[const SizedBox(height: AppSpacing.md), Text(_error!, style: AppTypography.error)],
            const SizedBox(height: AppSpacing.xl),
            PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_employeeId == null) {
      setState(() => _error = 'Personel seçin');
      return;
    }
    // "8.500" = sekiz bin beş yüz, "1250,50" = bin iki yüz elli virgül elli
    // (bütçe/masraf formlarıyla aynı Türkçe kural).
    final parsed = parseTrDecimal(_amountController.text, max: kMaxPaymentAmount);
    if (parsed.error != null) {
      setState(() => _error = parsed.error);
      return;
    }
    final amount = parsed.value;
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Tutar sıfırdan büyük olmalı.');
      return;
    }
    final period = _periodController.text.trim();
    if (!isValidPeriod(period)) {
      setState(() => _error = 'Ay YYYY-AA biçiminde olmalı (ör. 2026-09).');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(payrollRepositoryProvider)
          .create(
            employeeId: _employeeId!,
            period: period,
            paymentType: _type,
            amount: amount,
            paidDate: _isoDay(_paidDate),
            description: _descriptionController.text.trim(),
          );
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      // Backend'in Türkçe mesajı olduğu gibi gösterilir ("geçersiz personel",
      // "ödeme tutarı çok büyük ..."); genel bir hata metniyle değiştirilmez.
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

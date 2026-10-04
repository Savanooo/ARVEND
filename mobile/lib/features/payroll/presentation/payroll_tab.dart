import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../../projects/budget/domain/budget.dart' show formatTrDecimalInput, parseTrDecimal;
import '../data/payroll_providers.dart';
import '../domain/payroll.dart';

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

/// Mesai ekranının "Maaş" sekmesi (web'deki "Maaş ve Ödemeler" bölümünün
/// karşılığı). Ay seçici üst ekranla PAYLAŞILIR -- bu sekme kendi ayını
/// tutmaz, [month] ("YYYY-MM") alır.
///
/// Görünürlük çağıranda kararlaştırılır ve fail-CLOSED'dır (bkz.
/// AttendanceScreen): maaş tutarı hassas olduğu için mesainin "izin listesi
/// boşsa her şey görünür" davranışı burada KULLANILMAZ.
class PayrollTab extends ConsumerWidget {
  const PayrollTab({super.key, required this.month, required this.canManage});

  final String month;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monthAsync = ref.watch(payrollMonthProvider(month));
    void refresh() => ref.invalidate(payrollMonthProvider(month));

    return RefreshIndicator(
      onRefresh: () async => refresh(),
      child: AsyncStateView(
        value: monthAsync,
        onRetry: () async => refresh(),
        data: (context, data) => ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 88),
          children: [
            Text('Ödenecek', style: AppTypography.metadata),
            MoneyText(
              data.toPay,
              style: AppTypography.sectionTitle,
              color: data.toPay > 0 ? AppColors.danger : null,
            ),
            Text(
              '${data.waitingCount > 0 ? '${data.waitingCount} kişi bekliyor' : 'Bekleyen yok'}'
              '  ·  ödenen ${Formatters.money(data.paidTotal)}',
              style: AppTypography.helper,
            ),
            // Düğme satırın YANINDA değil altında: tema birincil düğmeyi tam
            // genişlik yapar (minimumSize: Size.fromHeight) ve bir Row içinde
            // sonsuz genişlik ister -- sahada o satır gri kutu olarak çıkardı.
            // Avans ayrı düğme: yalnızca formdaki "Tür" kutusunda dururken
            // sahada bulunamadı (2026-10). İkisi de Expanded içinde -- tema
            // düğmeleri tam genişlik yapar, Row'da sonlu genişlik şart.
            if (canManage) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: 'Ödeme Ekle',
                      icon: Icons.add,
                      onPressed: () => _showPaymentForm(context, data, onSaved: refresh),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: SecondaryButton(
                      label: 'Avans Ver',
                      icon: Icons.payments_outlined,
                      onPressed: () => _showPaymentForm(context, data, onSaved: refresh, type: 'avans'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            const AppSectionHeader(title: 'Personel'),
            if (data.summary.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: EmptyStateView(message: 'Bu ay için personel yok.', icon: Icons.people_outline),
              )
            else
              ...data.summary.map(
                (r) => _SummaryCard(
                  row: r,
                  onPay: canManage && r.isWaiting
                      ? () => _showPaymentForm(context, data, onSaved: refresh, payFor: r)
                      : null,
                  // Avans çoğu zaman ay başında, henüz hakediş yokken verilir:
                  // kalan sıfır olsa da sunulur (pasif personele değil).
                  onAdvance: canManage && r.isActive
                      ? () => _showPaymentForm(context, data, onSaved: refresh, payFor: r, type: 'avans')
                      : null,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: AppSpacing.lg),
              child: Text(
                'Hesaplanan: yevmiye tanımlıysa yevmiye × çalışılan gün (geldi = 1, yarım gün = 0,5), '
                'değilse aylık maaşın tamamı. Kalan = hesaplanan − maaş, avans ve mesai ödemeleri − '
                'önceki aydan devir. Prim ve diğer kalandan düşmez. Fazla ödeme sonraki aya devreder.',
                style: AppTypography.helper,
              ),
            ),
            const AppSectionHeader(title: 'Ödemeler'),
            if (data.payments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: EmptyStateView(message: 'Bu aya ait ödeme yok.', icon: Icons.payments_outlined),
              )
            else
              ...data.payments.map(
                (p) => AppListCard(
                  onTap: canManage ? () => _confirmDelete(context, ref, p, onDeleted: refresh) : null,
                  title: p.employeeName.isEmpty ? p.employeeId : p.employeeName,
                  subtitle: [
                    Formatters.longDate(p.paidDate),
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
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [payFor] verilirse (kartın "Öde"si) form o personel seçili ve tutar =
  /// kalan olarak açılır.
  void _showPaymentForm(
    BuildContext context,
    PayrollMonth data, {
    required VoidCallback onSaved,
    PayrollSummaryRow? payFor,
    String type = 'maaş',
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => PaymentFormSheet(
        employees: data.payableEmployees,
        initialPeriod: month,
        initialEmployeeId: payFor?.employeeId,
        // Avansta tutar önerilmez: kalan, avansın tutarı değildir.
        initialAmount: type == 'avans' ? null : payFor?.remaining,
        initialType: type,
        onSaved: onSaved,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    SalaryPayment p, {
    required VoidCallback onDeleted,
  }) async {
    // Para kaydı: kime, ne kadar, hangi tür -- yanlış satıra dokunup başka
    // bir ödemeyi silmek kolay (web ile aynı onay metni).
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
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.row, this.onPay, this.onAdvance});
  final PayrollSummaryRow row;
  final VoidCallback? onPay;
  final VoidCallback? onAdvance;

  String get _wage => switch (row.wageBasis) {
    'günlük' when row.dailyWage != null => '${Formatters.money(row.dailyWage!)}/gün',
    'aylık' when row.salary != null => '${Formatters.money(row.salary!)}/ay',
    _ => 'ücret tanımsız',
  };

  @override
  Widget build(BuildContext context) {
    final lines = [
      '${Formatters.decimal(row.workedDays)} gün · $_wage',
      if (row.hasWage) 'Hesaplanan ${Formatters.money(row.earned)} · ödenen ${Formatters.money(row.paidTotal)}',
      if (!row.hasWage && row.paidTotal > 0) 'Ödenen ${Formatters.money(row.paidTotal)}',
      if (row.carryOver > 0) '${Formatters.money(row.carryOver)} önceki aydan devir düşüldü',
      // Ay içinde verilen avans hakedişi geçebilir; ay ilerledikçe kapanır.
      if (row.remaining < 0) '${Formatters.money(-row.remaining)} fazla ödendi · ay sonunda kalırsa devreder',
      if (row.extraPaid > 0) '${Formatters.money(row.extraPaid)} prim/diğer',
    ];
    // "Ödendi" yalnızca gerçekten hakediş ödenmişse: hiç çalışmamış ve
    // ödeme almamış kişi, ya da hakedişini aşan avans alan kişi eskiden de
    // "Ödendi" görünüyordu.
    final (String, StatusTone) status = !row.hasWage
        ? ('Ücret tanımsız', StatusTone.muted)
        : row.isWaiting
        ? ('Bekliyor', StatusTone.gold)
        : row.remaining < 0
        ? ('Fazla ödendi', StatusTone.info)
        : row.earned == 0 && row.paidTotal == 0
        ? ('Çalışma yok', StatusTone.muted)
        : ('Ödendi', StatusTone.success);

    return AppCard(
      onTap: onPay,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.isActive ? row.fullName : '${row.fullName} (pasif)',
                  style: AppTypography.cardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                for (final l in lines) Text(l, style: AppTypography.metadata),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              StatusBadge(label: status.$1, tone: status.$2),
              if (row.isWaiting) ...[
                const SizedBox(height: AppSpacing.xs),
                MoneyText(row.remaining, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
                Text('kalan', style: AppTypography.helper),
              ],
              if (onPay != null)
                TextButton(
                  onPressed: onPay,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('Öde'),
                ),
              if (onAdvance != null)
                TextButton(
                  onPressed: onAdvance,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('Avans'),
                ),
            ],
          ),
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

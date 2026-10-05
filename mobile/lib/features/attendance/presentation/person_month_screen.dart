import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../../payroll/data/payroll_providers.dart';
import '../../payroll/domain/payroll.dart';
import '../../payroll/presentation/payroll_tab.dart';
import '../data/attendance_providers.dart';
import '../domain/attendance_people.dart';
import 'attendance_screen.dart';

const _days = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];

String _dayLabel(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}, ${_days[d.weekday - 1]}';
}

/// Bir personelin bir ayı, tek ekranda (BYZ'nin maaş ödeme sayfasının
/// karşılığı): maaş özeti + Öde/Avans, gün gün mesai, ödemeler. Mesai &
/// Maaş listesinde kişiye dokununca açılır.
class PersonMonthScreen extends ConsumerStatefulWidget {
  const PersonMonthScreen({super.key, required this.employeeId, required this.fullName, required this.initialMonth});

  final String employeeId;
  final String fullName;
  final DateTime initialMonth;

  @override
  ConsumerState<PersonMonthScreen> createState() => _PersonMonthScreenState();
}

class _PersonMonthScreenState extends ConsumerState<PersonMonthScreen> {
  late DateTime _month = widget.initialMonth;
  bool _pdfLoading = false;

  /// Maaş dökümü: sunucu PDF'i üretir, geçici dizine yazılır ve telefonun
  /// kendi PDF görüntüleyicisiyle açılır (oradan paylaşılır/kaydedilir) --
  /// proje dosyalarıyla aynı yol.
  Future<void> _openStatement() async {
    setState(() => _pdfLoading = true);
    try {
      final bytes = await ref.read(payrollRepositoryProvider).statementPdf(widget.employeeId, _key);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/maas-dokumu-$_key-${widget.employeeId}.pdf');
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFilex.open(file.path, type: 'application/pdf');
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF açılamadı: ${result.message}')));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on Exception catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF açılamadı.')));
      }
    } finally {
      if (mounted) setState(() => _pdfLoading = false);
    }
  }

  String get _key => monthKeyOf(_month);

  void _refresh() {
    ref.invalidate(attendanceListProvider(_key));
    ref.invalidate(payrollMonthProvider(_key));
  }

  /// Yeni kaydın varsayılan günü: içinde bulunulan aydaysa bugün, değilse
  /// o ayın ilk günü (geçmiş ayı düzeltirken bugün o aya düşmez).
  DateTime get _defaultDate {
    final now = DateTime.now();
    return now.year == _month.year && now.month == _month.month ? now : DateTime(_month.year, _month.month);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('attendance.manage');
    final canSeePayroll = user.canAccess('payroll.read');
    final canPay = canSeePayroll && user.canAccess('payroll.manage');

    final recordsAsync = ref.watch(attendanceListProvider(_key));
    final payrollAsync = canSeePayroll ? ref.watch(payrollMonthProvider(_key)) : null;
    final payroll = payrollAsync?.valueOrNull;
    final row = payroll?.summary.where((r) => r.employeeId == widget.employeeId).firstOrNull;
    final payments = payroll?.payments.where((p) => p.employeeId == widget.employeeId).toList() ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fullName),
        actions: [
          if (canSeePayroll)
            _pdfLoading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Maaş dökümü (PDF)',
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    onPressed: _openStatement,
                  ),
        ],
      ),
      body: Column(
        children: [
          MonthSwitcher(month: _month, onChanged: (m) => setState(() => _month = m)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: AsyncStateView(
                value: recordsAsync,
                onRetry: () async => _refresh(),
                data: (context, all) {
                  final records = all.where((r) => r.employeeId == widget.employeeId).toList()
                    ..sort((a, b) => b.date.compareTo(a.date));
                  final days = records.fold(0.0, (s, r) => s + attendanceDayValue(r.status));
                  final hours = records.fold(0.0, (s, r) => s + r.workHours);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xxl),
                    children: [
                      if (canSeePayroll && row != null) ...[
                        _PayrollSummaryCard(row: row),
                        if (canPay) ...[
                          const SizedBox(height: AppSpacing.md),
                          Row(
                            children: [
                              Expanded(
                                child: PrimaryButton(
                                  label: row.isWaiting ? 'Öde' : 'Ödeme Ekle',
                                  icon: Icons.payments_outlined,
                                  onPressed: () => showPaymentForm(
                                    context,
                                    employees: [row],
                                    month: _key,
                                    onSaved: _refresh,
                                    payFor: row,
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: SecondaryButton(
                                  label: 'Avans Ver',
                                  icon: Icons.savings_outlined,
                                  onPressed: () => showPaymentForm(
                                    context,
                                    employees: [row],
                                    month: _key,
                                    onSaved: _refresh,
                                    payFor: row,
                                    type: 'avans',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: AppSpacing.xl),
                      ] else if (canSeePayroll && payrollAsync!.isLoading) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      AppSectionHeader(
                        title: 'Mesai · ${Formatters.decimal(days)} gün · ${Formatters.decimal(hours)} sa',
                        trailing: canManage
                            ? TextButton.icon(
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Mesai Ekle'),
                                onPressed: () => showAttendanceForm(
                                  context,
                                  onSaved: _refresh,
                                  employeeId: widget.employeeId,
                                  employeeName: widget.fullName,
                                  initialDate: _defaultDate,
                                ),
                              )
                            : null,
                      ),
                      if (records.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                          child: Text('Bu ay mesai kaydı yok.', style: AppTypography.metadata),
                        )
                      else
                        for (final r in records)
                          AppListCard(
                            key: ValueKey('mesai-${r.id}'),
                            onTap: canManage ? () => showAttendanceForm(context, onSaved: _refresh, existing: r) : null,
                            title: _dayLabel(r.date),
                            subtitle: [attendanceTimeRange(r), if (r.note.isNotEmpty) r.note].join('  ·  '),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                StatusRegistry.build(r.status, StatusRegistry.attendance),
                                const SizedBox(height: AppSpacing.xs),
                                Text('${Formatters.decimal(r.workHours)} sa', style: AppTypography.metadata),
                              ],
                            ),
                          ),
                      if (canSeePayroll) ...[
                        const SizedBox(height: AppSpacing.xl),
                        AppSectionHeader(title: 'Ödemeler (${payments.length})'),
                        if (payments.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                            child: Text('Bu aya ait ödeme yok.', style: AppTypography.metadata),
                          )
                        else
                          for (final p in payments)
                            PaymentCard(
                              payment: p,
                              showName: false,
                              onTap: canPay ? () => confirmDeletePayment(context, ref, p, onDeleted: _refresh) : null,
                            ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PayrollSummaryCard extends StatelessWidget {
  const _PayrollSummaryCard({required this.row});
  final PayrollSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final status = payrollStatus(row);
    final wage = switch (row.wageBasis) {
      'günlük' when row.dailyWage != null => '${Formatters.money(row.dailyWage!)} / gün',
      'aylık' when row.salary != null => '${Formatters.money(row.salary!)} / ay',
      _ => 'Tanımsız',
    };
    return AppCard(
      key: const ValueKey('kisi-maas-ozet'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Kalan', style: AppTypography.metadata),
                    MoneyText(
                      row.isWaiting ? row.remaining : 0,
                      style: AppTypography.sectionTitle,
                      color: row.isWaiting ? AppColors.danger : null,
                    ),
                  ],
                ),
              ),
              StatusBadge(label: status.$1, tone: status.$2),
            ],
          ),
          const Divider(height: AppSpacing.xl),
          AppDataRow(label: 'Ücret', value: wage),
          AppDataRow(label: 'Çalışılan', value: '${Formatters.decimal(row.workedDays)} gün'),
          if (row.hasWage) AppDataRow(label: 'Hesaplanan', value: Formatters.money(row.earned)),
          AppDataRow(label: 'Ödenen', value: Formatters.money(row.paidTotal)),
          if (row.extraPaid > 0) AppDataRow(label: '  · prim/diğer', value: Formatters.money(row.extraPaid)),
          if (row.carryOver > 0) AppDataRow(label: 'Önceki aydan devir', value: '−${Formatters.money(row.carryOver)}'),
          if (row.remaining < 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                '${Formatters.money(-row.remaining)} fazla ödendi · ay sonunda kalırsa sonraki aya devreder.',
                style: AppTypography.helper,
              ),
            ),
        ],
      ),
    );
  }
}

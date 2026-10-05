import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../../payroll/data/payroll_providers.dart';
import '../../payroll/domain/payroll.dart';
import '../../payroll/presentation/payroll_tab.dart';
import '../domain/attendance_people.dart';
import 'person_month_screen.dart';
import '../data/attendance_providers.dart';
import '../domain/attendance.dart';

String _todayIso() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

/// Check-in/check-out yoksa gösterilecek metin ("'-' if absent").
String attendanceTimeRange(AttendanceRecord r) =>
    (r.checkIn.isNotEmpty || r.checkOut.isNotEmpty) ? '${r.checkIn}${r.checkOut.isNotEmpty ? '-${r.checkOut}' : ''}' : '-';

/// Faz "Mesai/Puantaj" — backend'de SAF elle giriş (bkz. domain notu:
/// GPS/geofence YOK), tek bir `work_hours` alanı var (mesai/fazla mesai
/// AYRIMI YOK), proje ilişkisi YOK (`attendance_logs`'ta `project_id`
/// kolonu HİÇ yok -- bkz. Phase 1 doğrulaması). Bu yüzden bu ekranda proje
/// bazlı bir görünüm YOKTUR ve saat hesaplaması/fazla mesai kuralı İCAT
/// EDİLMEZ -- yalnızca backend'in KENDİ döndürdüğü `work_hours` gösterilir.
///
/// Düzen (2026-10, sahadan): TEK liste -- her personel bir satır (o ayın
/// günü/saati, bugünün kaydı, maaş izni varsa kalan). Kişiye basınca o
/// kişinin ayı ayrı ekranda (PersonMonthScreen): maaş özeti, Öde/Avans,
/// gün gün mesai, ödemeler. Eskiden Puantaj/Maaş sekmeleri gün gün kayıtları
/// ve ödemeleri alt alta diziyordu, liste ekranlarca uzuyordu.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  DateTime _month = DateTime.now();

  String get _monthKey => monthKeyOf(_month);
  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  // Maaşın "hesaplanan"ı puantajdan gelir: mesai eklenince, düzeltilince
  // ya da silinince o ayın maaş tablosu da tazelenir.
  void _refresh() {
    ref.invalidate(attendanceListProvider(_monthKey));
    ref.invalidate(payrollMonthProvider(_monthKey));
  }

  @override
  Widget build(BuildContext context) {
    final recordsAsync = ref.watch(attendanceListProvider(_monthKey));
    final employees = ref.watch(employeesProvider).valueOrNull;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('attendance.manage');
    // Maaş tutarı hassas: mesainin yukarıdaki "izin listesi boşsa her şey
    // görünür" (fail-open) kuralı burada KULLANILMAZ -- canAccess fail-CLOSED'dır
    // (kullanıcı yüklenmemişse ya da izni yoksa maaş hiç görünmez, /payroll
    // hiç çağrılmaz). Web'deki "Mesai & Maaş" sayfasıyla aynı karar.
    final canSeePayroll = user.canAccess('payroll.read');
    final payroll = canSeePayroll ? ref.watch(payrollMonthProvider(_monthKey)).valueOrNull : null;

    return Scaffold(
      appBar: buildAppBar(canSeePayroll ? 'Mesai & Maaş' : 'Mesai'),
      floatingActionButton: canManage
          ? FloatingActionButton(
              tooltip: 'Mesai Ekle',
              onPressed: () => showAttendanceForm(context, onSaved: _refresh),
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          MonthSwitcher(month: _month, onChanged: (m) => setState(() => _month = m)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: AsyncStateView(
                value: recordsAsync,
                onRetry: () async => _refresh(),
                data: (context, records) {
                  final people = peopleForMonth(
                    employees: employees,
                    records: records,
                    payroll: payroll,
                    todayIso: _isCurrentMonth ? _todayIso() : null,
                  );
                  return _PeopleList(
                    people: people,
                    payroll: payroll,
                    showToday: _isCurrentMonth,
                    // Kişi ekranı AYNI sağlayıcıları (ay anahtarıyla) tazeler;
                    // dönüşte liste zaten güncel, yeniden istek gerekmez.
                    onOpen: (p) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PersonMonthScreen(
                          employeeId: p.employeeId,
                          fullName: p.fullName,
                          initialMonth: _month,
                        ),
                      ),
                    ),
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

String monthKeyOf(DateTime m) => '${m.year}-${m.month.toString().padLeft(2, '0')}';

/// Ay seçici (‹ 2026 / 10 › ve geçmiş/gelecek aydayken "Bugün").
class MonthSwitcher extends StatelessWidget {
  const MonthSwitcher({super.key, required this.month, required this.onChanged});

  final DateTime month;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Önceki ay',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => onChanged(DateTime(month.year, month.month - 1)),
          ),
          Text('${month.year} / ${month.month.toString().padLeft(2, '0')}', style: AppTypography.sectionTitle),
          IconButton(
            tooltip: 'Sonraki ay',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => onChanged(DateTime(month.year, month.month + 1)),
          ),
          if (!isCurrent) TextButton(onPressed: () => onChanged(DateTime.now()), child: const Text('Bugün')),
        ],
      ),
    );
  }
}

class _PeopleList extends StatelessWidget {
  const _PeopleList({required this.people, required this.payroll, required this.showToday, required this.onOpen});

  final List<PersonMonth> people;
  final PayrollMonth? payroll;
  final bool showToday;
  final ValueChanged<PersonMonth> onOpen;

  @override
  Widget build(BuildContext context) {
    final active = people.where((p) => p.isActive).toList();
    final missingToday = showToday ? active.where((p) => p.today == null).length : 0;
    final pay = payroll;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 88),
      children: [
        if (pay != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              children: [
                Text('Ödenecek ', style: AppTypography.metadata),
                MoneyText(
                  pay.toPay,
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                  color: pay.toPay > 0 ? AppColors.danger : null,
                ),
                Expanded(
                  child: Text(
                    '  ·  ${pay.waitingCount > 0 ? '${pay.waitingCount} kişi bekliyor' : 'bekleyen yok'}',
                    style: AppTypography.metadata,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (showToday && active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              missingToday == 0
                  ? 'Bugün herkesin kaydı girildi.'
                  : 'Bugün ${active.length - missingToday}/${active.length} kişinin kaydı girildi.',
              style: AppTypography.metadata.copyWith(color: missingToday == 0 ? null : AppColors.warning),
            ),
          ),
        AppSectionHeader(title: 'Personel (${people.length})'),
        if (people.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: EmptyStateView(message: 'Bu ay için personel yok.', icon: Icons.people_outline),
          )
        else
          for (final p in people) _PersonRow(person: p, showToday: showToday, onTap: () => onOpen(p)),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Text('Kişiye dokun: o ayın mesaisi, maaşı ve ödemeleri.', style: AppTypography.helper),
        ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, required this.showToday, required this.onTap});

  final PersonMonth person;
  final bool showToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final pay = p.payroll;
    final subtitle = [
      '${Formatters.decimal(p.workedDays)} gün · ${Formatters.decimal(p.workHours)} sa',
      if (showToday && p.isActive)
        p.today == null ? 'bugün kayıt yok' : 'bugün: ${StatusRegistry.attendance[p.today!.status]?.$1 ?? p.today!.status}',
    ].join('  ·  ');
    final Widget trailing;
    if (pay != null) {
      final status = payrollStatus(pay);
      trailing = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusBadge(label: status.$1, tone: status.$2),
          if (pay.isWaiting) ...[
            const SizedBox(height: AppSpacing.xs),
            MoneyText(pay.remaining, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
          ],
        ],
      );
    } else if (showToday && p.isActive && p.today == null) {
      trailing = Text(
        'Kayıt Yok',
        style: AppTypography.helper.copyWith(color: AppColors.warning, fontWeight: FontWeight.w700),
      );
    } else if (p.today != null) {
      trailing = StatusRegistry.build(p.today!.status, StatusRegistry.attendance);
    } else {
      trailing = const Icon(Icons.chevron_right, color: AppColors.textMuted);
    }
    return AppListCard(
      key: ValueKey('kisi-${p.employeeId}'),
      onTap: onTap,
      title: p.isActive ? p.fullName : '${p.fullName} (pasif)',
      subtitle: subtitle,
      trailing: trailing,
    );
  }
}

/// Mesai kaydı formunu açar. [existing] verilirse düzenleme; [employeeId]
/// verilirse (kişinin ekranından) personel sabit gelir.
Future<void> showAttendanceForm(
  BuildContext context, {
  required VoidCallback onSaved,
  AttendanceRecord? existing,
  String? employeeId,
  String? employeeName,
  DateTime? initialDate,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AttendanceFormSheet(
      existing: existing,
      onSaved: onSaved,
      employeeId: employeeId,
      employeeName: employeeName,
      initialDate: initialDate,
    ),
  );
}

/// Create + Edit AYNI form. Edit'te personel/tarih backend'de zaten
/// DEĞİŞTİRİLEMEZ (bkz. dosya başı yorumu) -- bu yüzden salt-okunur
/// gösterilir, yalnızca giriş/çıkış/saat/durum/not düzenlenebilir.
class AttendanceFormSheet extends ConsumerStatefulWidget {
  const AttendanceFormSheet({
    super.key,
    required this.existing,
    required this.onSaved,
    this.employeeId,
    this.employeeName,
    this.initialDate,
  });
  final AttendanceRecord? existing;
  final VoidCallback onSaved;

  /// Kişinin ekranından eklerken personel sabittir (seçici yok) -- personel
  /// listesini okuma izni (employees.read) olmasa da kayıt girilebilir.
  final String? employeeId;
  final String? employeeName;
  final DateTime? initialDate;

  bool get isEdit => existing != null;

  @override
  ConsumerState<AttendanceFormSheet> createState() => _AttendanceFormSheetState();
}

class _AttendanceFormSheetState extends ConsumerState<AttendanceFormSheet> {
  Employee? _employee;
  late DateTime _date = widget.initialDate ?? DateTime.now();
  late String _status;
  late final TextEditingController _checkInController;
  late final TextEditingController _checkOutController;
  late final TextEditingController _hoursController;
  late final TextEditingController _noteController;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _status = e?.status ?? 'geldi';
    _checkInController = TextEditingController(text: e?.checkIn ?? '08:00');
    _checkOutController = TextEditingController(text: e?.checkOut ?? '17:00');
    _hoursController = TextEditingController(text: e != null ? _numStr(e.workHours) : '8');
    _noteController = TextEditingController(text: e?.note ?? '');
    if (e != null) {
      final parsed = DateTime.tryParse(e.date);
      if (parsed != null) _date = parsed;
    }
  }

  static String _numStr(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _checkInController.dispose();
    _checkOutController.dispose();
    _hoursController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Personel seçici yalnızca serbest eklemede: düzenlemede ve kişinin
    // ekranından eklerken personel sabit, liste hiç istenmez.
    final employeesAsync = widget.isEdit || widget.employeeId != null ? null : ref.watch(employeesProvider);

    return Padding(
      padding: EdgeInsets.only(left: AppSpacing.xl, right: AppSpacing.xl, top: AppSpacing.xl, bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.isEdit ? 'Mesai Kaydını Düzenle' : 'Mesai Kaydı Ekle',
                style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.lg),
            if (widget.isEdit) ...[
              AppDataRow(
                label: 'Personel',
                value: widget.existing!.employeeName.isEmpty ? widget.existing!.employeeId : widget.existing!.employeeName,
              ),
              AppDataRow(label: 'Tarih', value: widget.existing!.date),
              const SizedBox(height: AppSpacing.xs),
              Text('Personel ve tarih düzenlenemez.', style: AppTypography.helper),
            ] else if (widget.employeeId != null)
              AppDataRow(label: 'Personel', value: widget.employeeName ?? widget.employeeId!)
            else
              employeesAsync!.when(
                data: (employees) => DropdownButtonFormField<Employee>(
                  initialValue: _employee,
                  decoration: const InputDecoration(labelText: 'Personel'),
                  items: employees.map((e) => DropdownMenuItem(value: e, child: Text(e.fullName))).toList(),
                  onChanged: (v) => setState(() => _employee = v),
                ),
                loading: () => const LinearProgressIndicator(),
                error: (e, st) => const Text('Personel listesi alınamadı'),
              ),
            if (!widget.isEdit) ...[
              const SizedBox(height: AppSpacing.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tarih'),
                subtitle: Text('${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}'),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.textMuted),
                onTap: () async {
                  final picked = await showDatePicker(
                      context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
                  if (picked != null) setState(() => _date = picked);
                },
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Durum'),
              items: kAttendanceStatuses
                  .map((s) => DropdownMenuItem(value: s, child: Text(StatusRegistry.attendance[s]!.$1)))
                  .toList(),
              onChanged: (v) => setState(() => _status = v!),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(controller: _checkInController, decoration: const InputDecoration(labelText: 'Giriş')),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(controller: _checkOutController, decoration: const InputDecoration(labelText: 'Çıkış')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _hoursController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Çalışma Saati'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Not (opsiyonel)'),
              maxLines: 2,
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
            // Web puantaj tablosundaki "Sil"in karşılığı (aynı izin:
            // attendance.manage -- form zaten yalnızca o izinle açılır).
            if (widget.isEdit) ...[
              const SizedBox(height: AppSpacing.sm),
              TextButton.icon(
                onPressed: _submitting ? null : _delete,
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Kaydı Sil'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final r = widget.existing!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mesai kaydı silinsin mi?'),
        content: Text(
          '${r.employeeName} — ${Formatters.longDate(r.date)} (${r.status})\n'
          'Bu ayın maaş hesabı da buna göre değişir.',
        ),
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
    if (ok != true || !mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(attendanceRepositoryProvider).delete(r.id);
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit() async {
    final employeeId = widget.employeeId ?? _employee?.id;
    if (!widget.isEdit && employeeId == null) {
      setState(() => _error = 'Personel seçin');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(attendanceRepositoryProvider);
      final workHours = double.tryParse(_hoursController.text.replaceAll(',', '.')) ?? 0;
      if (widget.isEdit) {
        await repo.update(
          widget.existing!.id,
          checkIn: _checkInController.text.trim(),
          checkOut: _checkOutController.text.trim(),
          workHours: workHours,
          status: _status,
          note: _noteController.text.trim(),
        );
      } else {
        await repo.create(
          employeeId: employeeId!,
          date: '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
          checkIn: _checkInController.text.trim(),
          checkOut: _checkOutController.text.trim(),
          workHours: workHours,
          status: _status,
          note: _noteController.text.trim(),
        );
      }
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      // Backend, AYNI personel + AYNI tarih için 409 + "bu personel için bu
      // tarihte zaten mesai kaydı var" döner (DB UNIQUE(employee_id, date)
      // -- bkz. Phase 1 doğrulaması) -- burada AYRI bir çakışma modeli İCAT
      // EDİLMEZ, backend'in kendi mesajı olduğu gibi gösterilir.
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

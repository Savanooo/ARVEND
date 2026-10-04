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
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../payroll/data/payroll_providers.dart';
import '../../payroll/presentation/payroll_tab.dart';
import '../data/attendance_providers.dart';
import '../domain/attendance.dart';

String _todayIso() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

/// Check-in/check-out yoksa gösterilecek metin -- Bugün/Aylık listelerinde
/// ORTAK kullanılır (bkz. Faz 3 modül talimatı: "'-' if absent").
String _timeRange(AttendanceRecord r) =>
    (r.checkIn.isNotEmpty || r.checkOut.isNotEmpty) ? '${r.checkIn}${r.checkOut.isNotEmpty ? '-${r.checkOut}' : ''}' : '-';

/// Faz "Mesai/Puantaj" — backend'de SAF elle giriş (bkz. domain notu:
/// GPS/geofence YOK), tek bir `work_hours` alanı var (mesai/fazla mesai
/// AYRIMI YOK), proje ilişkisi YOK (`attendance_logs`'ta `project_id`
/// kolonu HİÇ yok -- bkz. Phase 1 doğrulaması). Bu yüzden bu ekranda proje
/// bazlı bir görünüm YOKTUR ve saat hesaplaması/fazla mesai kuralı İCAT
/// EDİLMEZ -- yalnızca backend'in KENDİ döndürdüğü `work_hours` gösterilir.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> with SingleTickerProviderStateMixin {
  // Puantaj | Maaş. Maaş sekmesi yalnızca payroll.read varken görünür; yoksa
  // controller hiç kullanılmaz ve ekran eskisi gibi tek listedir.
  //
  // initState'te OLUŞTURULUR, `late final ... = ` ile tembel değil: maaş izni
  // olmayan kullanıcıda build hiç dokunmadığı için tembel alan ilk kez
  // dispose()'ta oluşuyor, ticker devre dışı bir elemana bakıp çöküyordu
  // (payroll_workflow_test bunu yakaladı).
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_onTabChanged);
  }

  void _onTabChanged() {
    // FAB yalnızca Puantaj sekmesinde -- sekme değişince yeniden çiz.
    if (!_tabs.indexIsChanging) setState(() {});
  }
  DateTime _month = DateTime.now();
  String? _employeeFilter;
  String? _statusFilter;

  String get _monthKey => '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  // Maaş sekmesinin "hesaplanan"ı puantajdan gelir: mesai eklenince,
  // düzeltilince ya da silinince o ayın maaş tablosu da tazelenir.
  void _refresh() {
    ref.invalidate(attendanceListProvider(_monthKey));
    ref.invalidate(payrollMonthProvider(_monthKey));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recordsAsync = ref.watch(attendanceListProvider(_monthKey));
    final employeesAsync = ref.watch(employeesProvider);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('attendance.manage');
    // Maaş tutarı hassas: mesainin yukarıdaki "izin listesi boşsa her şey
    // görünür" (fail-open) kuralı burada KULLANILMAZ -- canAccess fail-CLOSED'dır
    // (kullanıcı yüklenmemişse ya da izni yoksa sekme hiç yok, /payroll hiç
    // çağrılmaz). Web'deki "Mesai & Maaş" sayfasıyla aynı karar.
    final canSeePayroll = user.canAccess('payroll.read');
    final canPay = canSeePayroll && user.canAccess('payroll.manage');
    final onPuantaj = !canSeePayroll || _tabs.index == 0;

    final attendanceBody = RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: AsyncStateView(
        value: recordsAsync,
        onRetry: () async => _refresh(),
        data: (context, records) => employeesAsync.when(
          loading: () => _buildList(context, records, const [], canManage),
          error: (_, _) => _buildList(context, records, const [], canManage),
          data: (employees) => _buildList(context, records, employees, canManage),
        ),
      ),
    );

    return Scaffold(
      appBar: buildAppBar(canSeePayroll ? 'Mesai & Maaş' : 'Mesai'),
      floatingActionButton: canManage && onPuantaj
          ? FloatingActionButton(
              onPressed: () => _showFormSheet(context),
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                ),
                Text('${_month.year} / ${_month.month.toString().padLeft(2, '0')}', style: AppTypography.sectionTitle),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                ),
                if (!_isCurrentMonth)
                  TextButton(
                    onPressed: () => setState(() => _month = DateTime.now()),
                    child: const Text('Bugün'),
                  ),
              ],
            ),
          ),
          if (canSeePayroll)
            TabBar(
              controller: _tabs,
              tabs: const [Tab(text: 'Puantaj'), Tab(text: 'Maaş')],
            ),
          Expanded(
            child: canSeePayroll
                ? TabBarView(
                    controller: _tabs,
                    children: [
                      attendanceBody,
                      PayrollTab(month: _monthKey, canManage: canPay),
                    ],
                  )
                : attendanceBody,
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, List<AttendanceRecord> records, List<Employee> employees, bool canManage) {
    final filtered = records
        .where((r) => attendanceMatchesFilters(r, employeeFilter: _employeeFilter, statusFilter: _statusFilter))
        .toList();

    final todaysRecords = records.where((r) => r.date == _todayIso()).toList();
    final missingToday = _isCurrentMonth ? missingAttendanceFor(employees, todaysRecords) : const <Employee>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 88),
      children: [
        if (_isCurrentMonth) ...[
          const AppSectionHeader(title: 'Bugün'),
          if (todaysRecords.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('Bugün için kayıt girilmedi.', style: AppTypography.metadata),
            )
          else
            ...todaysRecords.map((r) => AppListCard(
                  title: r.employeeName.isEmpty ? r.employeeId : r.employeeName,
                  subtitle: _timeRange(r),
                  trailing: _AttendanceTrailing(record: r),
                )),
          if (missingToday.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            const AppSectionHeader(title: 'Eksik Kayıtlar'),
            ...missingToday.map((e) => _MissingEmployeeRow(employee: e)),
          ],
          const SizedBox(height: AppSpacing.lg),
        ],
        const AppSectionHeader(title: 'Aylık / Geçmiş'),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: 200,
          child: DropdownButtonFormField<String>(
            initialValue: _employeeFilter ?? '',
            decoration: const InputDecoration(labelText: 'Personel', isDense: true),
            items: [
              const DropdownMenuItem(value: '', child: Text('Tüm personel')),
              ...employees.map((e) => DropdownMenuItem(value: e.id, child: Text(e.fullName, overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (v) => setState(() => _employeeFilter = (v == null || v.isEmpty) ? null : v),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppFilterBar(
          wrap: true,
          chips: [
            for (final s in kAttendanceStatuses)
              AppFilterChipData(
                label: StatusRegistry.attendance[s]!.$1,
                selected: _statusFilter == s,
                onTap: () => setState(() => _statusFilter = _statusFilter == s ? null : s),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: EmptyStateView(message: 'Bu filtreye uyan kayıt yok.', icon: Icons.event_note_outlined),
          )
        else
          ...filtered.map((r) => AppListCard(
                onTap: canManage ? () => _showFormSheet(context, existing: r) : null,
                title: r.employeeName.isEmpty ? r.employeeId : r.employeeName,
                subtitle: [
                  r.date,
                  _timeRange(r),
                  if (r.note.isNotEmpty) r.note,
                ].join('  ·  '),
                trailing: _AttendanceTrailing(record: r),
              )),
      ],
    );
  }

  void _showFormSheet(BuildContext context, {AttendanceRecord? existing}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _AttendanceFormSheet(existing: existing, onSaved: _refresh),
    );
  }
}

/// Bugün/Aylık listelerinde ORTAK trailing: durum rozeti + çalışma saati
/// (saat PARA DEĞİL -- bu yüzden MoneyText değil düz Text kullanılır).
class _AttendanceTrailing extends StatelessWidget {
  const _AttendanceTrailing({required this.record});
  final AttendanceRecord record;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        StatusRegistry.build(record.status, StatusRegistry.attendance),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${record.workHours.toStringAsFixed(record.workHours.truncateToDouble() == record.workHours ? 0 : 1)} sa',
          style: AppTypography.metadata,
        ),
      ],
    );
  }
}

/// "Eksik Kayıtlar" -- `missingAttendanceFor` sonucunu "Bugün" kayıt
/// listesinden AÇIKÇA ayırt edilebilir şekilde gösterir (bkz. Faz 3 modül
/// talimatı). Bu sert bir hata değil, "aksiyon gerekir" durumudur -- bu
/// yüzden danger değil warning tonu kullanılır (bkz. StatusTone doc-comment).
class _MissingEmployeeRow extends StatelessWidget {
  const _MissingEmployeeRow({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    return AppListCard(
      leading: const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 20),
      title: employee.fullName,
      subtitle: employee.position.isEmpty ? null : employee.position,
      trailing: Text(
        'Kayıt Yok',
        style: AppTypography.helper.copyWith(color: AppColors.warning, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Create + Edit AYNI form. Edit'te personel/tarih backend'de zaten
/// DEĞİŞTİRİLEMEZ (bkz. dosya başı yorumu) -- bu yüzden salt-okunur
/// gösterilir, yalnızca giriş/çıkış/saat/durum/not düzenlenebilir.
class _AttendanceFormSheet extends ConsumerStatefulWidget {
  const _AttendanceFormSheet({required this.existing, required this.onSaved});
  final AttendanceRecord? existing;
  final VoidCallback onSaved;

  bool get isEdit => existing != null;

  @override
  ConsumerState<_AttendanceFormSheet> createState() => _AttendanceFormSheetState();
}

class _AttendanceFormSheetState extends ConsumerState<_AttendanceFormSheet> {
  Employee? _employee;
  DateTime _date = DateTime.now();
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
    final employeesAsync = ref.watch(employeesProvider);

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
            ] else
              employeesAsync.when(
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
    if (!widget.isEdit && _employee == null) {
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
          employeeId: _employee!.id,
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

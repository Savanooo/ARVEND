import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/attendance_providers.dart';
import '../domain/attendance.dart';

String _todayIso() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

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

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  DateTime _month = DateTime.now();
  String? _employeeFilter;
  String? _statusFilter;

  String get _monthKey => '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  void _refresh() => ref.invalidate(attendanceListProvider(_monthKey));

  @override
  Widget build(BuildContext context) {
    final recordsAsync = ref.watch(attendanceListProvider(_monthKey));
    final employeesAsync = ref.watch(employeesProvider);
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('attendance.manage');

    return Scaffold(
      appBar: AppBar(title: const Text('Mesai')),
      floatingActionButton: canManage
          ? FloatingActionButton(
              onPressed: () => _showFormSheet(context),
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                ),
                Text('${_month.year} / ${_month.month.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
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
          Expanded(
            child: RefreshIndicator(
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
            ),
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
      children: [
        if (_isCurrentMonth) _TodaySection(records: todaysRecords, missing: missingToday),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
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
            ...kAttendanceStatuses.map((s) => FilterChip(
                  label: Text(StatusRegistry.attendance[s]!.$1),
                  selected: _statusFilter == s,
                  onSelected: (v) => setState(() => _statusFilter = v ? s : null),
                )),
          ],
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('Bu filtreye uyan kayıt yok.', style: TextStyle(color: Colors.grey))),
          )
        else
          ...filtered.map((r) => Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  onTap: canManage ? () => _showFormSheet(context, existing: r) : null,
                  title: Text(r.employeeName.isEmpty ? r.employeeId : r.employeeName),
                  subtitle: Text([
                    r.date,
                    if (r.checkIn.isNotEmpty || r.checkOut.isNotEmpty) '${r.checkIn}${r.checkOut.isNotEmpty ? '-${r.checkOut}' : ''}',
                    if (r.note.isNotEmpty) r.note,
                  ].join('  ·  '), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusRegistry.build(r.status, StatusRegistry.attendance),
                      const SizedBox(height: 4),
                      Text('${r.workHours.toStringAsFixed(r.workHours.truncateToDouble() == r.workHours ? 0 : 1)} sa',
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                    ],
                  ),
                ),
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

class _TodaySection extends StatelessWidget {
  const _TodaySection({required this.records, required this.missing});
  final List<AttendanceRecord> records;
  final List<Employee> missing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bugün', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (records.isEmpty)
              const Text('Bugün için kayıt girilmedi.', style: TextStyle(color: Colors.grey, fontSize: 13))
            else
              ...records.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text(r.employeeName.isEmpty ? r.employeeId : r.employeeName)),
                        StatusRegistry.build(r.status, StatusRegistry.attendance),
                      ],
                    ),
                  )),
            if (missing.isNotEmpty) ...[
              const Divider(height: 20),
              const Text('Kaydı girilmemiş', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: AppColors.danger)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: missing
                    .map((e) => Chip(
                          label: Text(e.fullName, style: const TextStyle(fontSize: 12)),
                          backgroundColor: AppColors.danger.withValues(alpha: 0.08),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
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
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.isEdit ? 'Mesai Kaydını Düzenle' : 'Mesai Kaydı Ekle',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 16),
            if (widget.isEdit)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(widget.existing!.employeeName.isEmpty ? widget.existing!.employeeId : widget.existing!.employeeName),
                subtitle: Text('${widget.existing!.date} — personel/tarih düzenlenemez'),
              )
            else
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
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tarih'),
                subtitle: Text('${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}'),
                onTap: () async {
                  final picked = await showDatePicker(
                      context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
                  if (picked != null) setState(() => _date = picked);
                },
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Durum'),
              items: kAttendanceStatuses
                  .map((s) => DropdownMenuItem(value: s, child: Text(StatusRegistry.attendance[s]!.$1)))
                  .toList(),
              onChanged: (v) => setState(() => _status = v!),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(controller: _checkInController, decoration: const InputDecoration(labelText: 'Giriş')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _checkOutController, decoration: const InputDecoration(labelText: 'Çıkış')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hoursController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Çalışma Saati'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Not (opsiyonel)'),
              maxLines: 2,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
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

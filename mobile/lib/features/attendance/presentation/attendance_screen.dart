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
import '../domain/attendance_entry.dart';
import '../domain/attendance_people.dart';
import 'person_month_screen.dart';
import '../data/attendance_providers.dart';
import '../domain/attendance.dart';
import '../../../core/widgets/app_sheet.dart';

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
  return showAppSheet(
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

/// Mesai girişi: tek gün, TOPLU (kişi(ler) + tarih aralığı) ve düzenleme
/// aynı form. Düzenlemede personel/tarih backend'de DEĞİŞTİRİLEMEZ -- bu
/// yüzden salt-okunur; yalnızca durum/giriş/çıkış/saat/not düzenlenir.
///
/// Toplu giriş (sahadan, 2026-10: "adamı seçecek, ayın 1'inden 5'ine"):
/// sunucuda toplu uç yok, her gün için ayrı POST /attendance atılır. Aynı
/// kişi + aynı güne ikinci kayıt sunucuda 409'dur -- toplu girişte hata
/// değil "zaten kayıtlıydı, atlandı" sayılır. Başka bir hata (yetki, ağ)
/// girişi durdurur; o ana kadar eklenenler kalır ve sonuç söylenir.
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
  bool _bulk = false;
  String? _employeeId; // tek gün, serbest seçim
  final Set<String> _bulkIds = {}; // toplu, serbest seçim
  // İleri bir ayın ekranından açılsa bile bugünden ileri başlamaz (ileri
  // tarihe mesai girilemez; seçici de bugünün ötesine izin vermez).
  late DateTime _date = clampToAttendanceDay(widget.initialDate ?? DateTime.now());
  late DateTimeRange _range = DateTimeRange(start: DateTime(_date.year, _date.month), end: _date);
  bool _skipSundays = true;
  late String _status;
  late String _checkIn;
  late String _checkOut;
  late final TextEditingController _hoursController;
  late final TextEditingController _noteController;
  bool _hoursEdited = false;
  bool _submitting = false;
  int _done = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _status = e?.status ?? 'geldi';
    _checkIn = (e?.checkIn.isNotEmpty ?? false) ? e!.checkIn : '08:00';
    _checkOut = (e?.checkOut.isNotEmpty ?? false) ? e!.checkOut : '17:00';
    // Saatli bir kayıtta kayıtlı saat korunur. "Gelmedi/izinli" kaydında
    // saat 0'dır ve anlamsızdır: "geldi"ye çevrilince 08:00–17:00
    // gösterilirken 0 saat kaydediliyordu -- saat giriş-çıkıştan hesaplanır.
    _hoursController = TextEditingController(
      text: e != null && statusHasHours(e.status)
          ? _numStr(e.workHours)
          : _numStr(hoursBetween(_checkIn, _checkOut) ?? 8),
    );
    // Düzenlemede kayıtlı saat korunur; yalnızca saatler değişince yeniden hesaplanır.
    _hoursEdited = false;
    _noteController = TextEditingController(text: e?.note ?? '');
    if (e != null) {
      final parsed = DateTime.tryParse(e.date);
      if (parsed != null) _date = parsed;
    }
  }

  static String _numStr(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
  static String _d(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  void dispose() {
    _hoursController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  bool get _fixedPerson => widget.employeeId != null;

  List<String> get _targetIds {
    if (_fixedPerson) return [widget.employeeId!];
    if (_bulk) return _bulkIds.toList();
    return [?_employeeId];
  }

  List<DateTime> get _targetDays => _bulk ? entryDays(_range.start, _range.end, skipSundays: _skipSundays) : [_date];

  Future<void> _pickTime({required bool checkIn}) async {
    final current = checkIn ? _checkIn : _checkOut;
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.tryParse(parts.first) ?? 8, minute: int.tryParse(parts.last) ?? 0),
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (picked == null) return;
    final v = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (checkIn) {
        _checkIn = v;
      } else {
        _checkOut = v;
      }
      final h = hoursBetween(_checkIn, _checkOut);
      if (h != null && !_hoursEdited) _hoursController.text = _numStr(h);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Personel listesi yalnızca serbest seçimde istenir: düzenlemede ve
    // kişinin ekranından eklerken personel sabit.
    final employeesAsync = widget.isEdit || _fixedPerson ? null : ref.watch(employeesProvider);
    final hasHours = statusHasHours(_status);
    final total = _targetIds.length * _targetDays.length;

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
            Text(widget.isEdit ? 'Mesai Kaydını Düzenle' : 'Mesai Gir',
                style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.md),
            if (!widget.isEdit) ...[
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Tek gün'), icon: Icon(Icons.today_outlined, size: 18)),
                  ButtonSegment(value: true, label: Text('Toplu'), icon: Icon(Icons.date_range_outlined, size: 18)),
                ],
                selected: {_bulk},
                showSelectedIcon: false,
                onSelectionChanged: _submitting ? null : (v) => setState(() => _bulk = v.first),
              ),
              const SizedBox(height: AppSpacing.md),
            ],

            // --- Kim
            const Text('KİM', style: AppTypography.overline),
            const SizedBox(height: AppSpacing.xs),
            if (widget.isEdit) ...[
              AppDataRow(
                label: 'Personel',
                value: widget.existing!.employeeName.isEmpty ? widget.existing!.employeeId : widget.existing!.employeeName,
              ),
              AppDataRow(label: 'Tarih', value: _d(_date)),
              Text('Personel ve tarih düzenlenemez.', style: AppTypography.helper),
            ] else if (_fixedPerson)
              AppDataRow(label: 'Personel', value: widget.employeeName ?? widget.employeeId!)
            else
              employeesAsync!.when(
                data: (employees) => _bulk
                    ? _BulkPeoplePicker(
                        employees: employees,
                        selected: _bulkIds,
                        onChanged: () => setState(() {}),
                      )
                    : DropdownButtonFormField<String>(
                        initialValue: _employeeId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Personel'),
                        items: [
                          for (final e in employees)
                            DropdownMenuItem(value: e.id, child: Text(e.fullName, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) => setState(() => _employeeId = v),
                      ),
                loading: () => const LinearProgressIndicator(),
                error: (e, st) => Text('Personel listesi alınamadı', style: AppTypography.error),
              ),

            // --- Ne zaman
            if (!widget.isEdit) ...[
              const SizedBox(height: AppSpacing.lg),
              const Text('NE ZAMAN', style: AppTypography.overline),
              if (!_bulk)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: Text(_d(_date)),
                  subtitle: const Text('Tarihi değiştir'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: clampToAttendanceDay(_date),
                      firstDate: DateTime(2020),
                      lastDate: attendanceLastDay(),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                )
              else ...[
                ListTile(
                  key: const ValueKey('mesai-aralik'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.date_range_outlined),
                  title: Text('${_d(_range.start)} – ${_d(_range.end)}'),
                  subtitle: Text('${_targetDays.length} gün${_skipSundays ? ' (pazarlar hariç)' : ''} · aralığı değiştir'),
                  onTap: () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      initialDateRange: DateTimeRange(
                        start: clampToAttendanceDay(_range.start),
                        end: clampToAttendanceDay(_range.end),
                      ),
                      firstDate: DateTime(2020),
                      lastDate: attendanceLastDay(),
                    );
                    if (picked != null) setState(() => _range = picked);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pazar günlerini atla'),
                  value: _skipSundays,
                  onChanged: (v) => setState(() => _skipSundays = v),
                ),
              ],
            ],

            // --- Durum
            const SizedBox(height: AppSpacing.lg),
            const Text('DURUM', style: AppTypography.overline),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (final s in kAttendanceStatuses)
                  ChoiceChip(
                    label: Text(StatusRegistry.attendance[s]!.$1),
                    selected: _status == s,
                    onSelected: (_) => setState(() {
                      // Saatsiz bir durumdan (gelmedi/izinli) saatliye
                      // geçerken, elle girilmemişse saat giriş-çıkıştan
                      // yeniden hesaplanır -- 0 saat taşınmaz.
                      final hadHours = statusHasHours(_status);
                      _status = s;
                      if (!hadHours && statusHasHours(s) && !_hoursEdited) {
                        final h = hoursBetween(_checkIn, _checkOut);
                        if (h != null) _hoursController.text = _numStr(h);
                      }
                    }),
                  ),
              ],
            ),
            if (hasHours) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _TimeTile(label: 'Giriş', value: _checkIn, onTap: () => _pickTime(checkIn: true)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _TimeTile(label: 'Çıkış', value: _checkOut, onTap: () => _pickTime(checkIn: false)),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                key: const Key('mesai-saat'),
                controller: _hoursController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _hoursEdited = true,
                decoration: const InputDecoration(
                  labelText: 'Çalışma saati',
                  helperText: 'Giriş-çıkıştan hesaplanır, istersen değiştir.',
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Not (opsiyonel)'),
              maxLines: 2,
            ),
            if (_bulk && !widget.isEdit) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                total == 0
                    ? 'Kişi ve tarih aralığı seç.'
                    : '${_targetIds.length} kişi × ${_targetDays.length} gün = $total kayıt girilecek.',
                key: const ValueKey('mesai-toplu-ozet'),
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
            if (_submitting && _bulk) ...[
              const SizedBox(height: AppSpacing.sm),
              LinearProgressIndicator(value: total == 0 ? null : _done / total),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(_error!, style: AppTypography.error),
            ],
            const SizedBox(height: AppSpacing.xl),
            PrimaryButton(
              label: _bulk && !widget.isEdit ? (total > 0 ? '$total kaydı gir' : 'Kaydet') : 'Kaydet',
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
    final ids = _targetIds;
    if (!widget.isEdit && ids.isEmpty) {
      setState(() => _error = _bulk ? 'En az bir kişi seç.' : 'Personel seç.');
      return;
    }
    final days = _targetDays;
    if (!widget.isEdit && days.isEmpty) {
      setState(() => _error = 'Seçilen aralıkta girilecek gün yok.');
      return;
    }
    final hasHours = statusHasHours(_status);
    final parsedHours = hasHours ? parseWorkHours(_hoursController.text) : 0.0;
    if (parsedHours == null) {
      setState(() => _error = 'Çalışma saati geçersiz: 0 ile 24 arasında bir sayı gir (ör. 8 ya da 7,5).');
      return;
    }
    final workHours = parsedHours;
    final checkIn = hasHours ? _checkIn : '';
    final checkOut = hasHours ? _checkOut : '';
    final note = _noteController.text.trim();
    setState(() {
      _submitting = true;
      _error = null;
      _done = 0;
    });
    final repo = ref.read(attendanceRepositoryProvider);
    try {
      if (widget.isEdit) {
        await repo.update(
          widget.existing!.id,
          checkIn: checkIn,
          checkOut: checkOut,
          workHours: workHours,
          status: _status,
          note: note,
        );
        widget.onSaved();
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (!_bulk) {
        await repo.create(
          employeeId: ids.single,
          date: isoDate(_date),
          checkIn: checkIn,
          checkOut: checkOut,
          workHours: workHours,
          status: _status,
          note: note,
        );
        widget.onSaved();
        if (mounted) Navigator.of(context).pop();
        return;
      }

      var created = 0, skipped = 0;
      String? stopError;
      outer:
      for (final id in ids) {
        for (final d in days) {
          try {
            await repo.create(
              employeeId: id,
              date: isoDate(d),
              checkIn: checkIn,
              checkOut: checkOut,
              workHours: workHours,
              status: _status,
              note: note,
            );
            created++;
          } on ApiException catch (e) {
            if (e.statusCode == 409) {
              skipped++;
            } else {
              stopError = e.message;
              break outer;
            }
          }
          if (mounted) setState(() => _done = created + skipped);
        }
      }
      final result = BulkEntryResult(created: created, skipped: skipped, error: stopError);
      if (created > 0 || skipped > 0) widget.onSaved();
      if (!mounted) return;
      if (stopError == null) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.summary)));
      } else {
        setState(() => _error = result.summary);
      }
    } on ApiException catch (e) {
      // Backend'in Türkçe mesajı olduğu gibi (ör. aynı gün 409: "bu personel
      // için bu tarihte zaten mesai kaydı var").
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _TimeTile extends StatelessWidget {
  const _TimeTile({required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.schedule, size: 18)),
        child: Text(value, style: AppTypography.body),
      ),
    );
  }
}

/// Toplu girişte kişi seçimi: çoklu seçim + "Tümü".
class _BulkPeoplePicker extends StatelessWidget {
  const _BulkPeoplePicker({required this.employees, required this.selected, required this.onChanged});
  final List<Employee> employees;
  final Set<String> selected;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final active = employees.where((e) => e.isActive).toList();
    final all = active.isNotEmpty && active.every((e) => selected.contains(e.id));
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        FilterChip(
          label: Text(all ? 'Hiçbiri' : 'Tümü (${active.length})'),
          selected: false,
          onSelected: (_) {
            if (all) {
              selected.clear();
            } else {
              selected.addAll(active.map((e) => e.id));
            }
            onChanged();
          },
        ),
        for (final e in active)
          FilterChip(
            label: Text(e.fullName),
            selected: selected.contains(e.id),
            onSelected: (v) {
              v ? selected.add(e.id) : selected.remove(e.id);
              onChanged();
            },
          ),
      ],
    );
  }
}

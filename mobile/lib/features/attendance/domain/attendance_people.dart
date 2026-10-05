import '../../payroll/domain/payroll.dart';
import 'attendance.dart';

/// Mesai & Maaş ekranının TEK listesinde bir satır: bir personelin o ayı.
/// Eskiden ekran gün gün kayıtları ve ödemeleri ayrı ayrı alt alta
/// diziyordu; sahada (2026-10) "liste tek olsun, kişiye basınca hepsi
/// gelsin" istendi. Ayrıntı kişinin kendi ekranında.
class PersonMonth {
  const PersonMonth({
    required this.employeeId,
    required this.fullName,
    required this.position,
    required this.isActive,
    required this.workedDays,
    required this.workHours,
    required this.records,
    this.today,
    this.payroll,
  });

  final String employeeId;
  final String fullName;
  final String position;
  final bool isActive;

  /// geldi = 1, yarım gün = 0.5 (backend PayrollSummaryByPeriod ile aynı).
  final double workedDays;
  final double workHours;

  /// Bu kişinin o aydaki kayıtları, en yeni gün önce.
  final List<AttendanceRecord> records;

  /// Bugünün kaydı (yalnızca içinde bulunulan ay için anlamlı).
  final AttendanceRecord? today;

  /// Maaş satırı -- yalnızca payroll.read varken ve sunucu döndürdüyse.
  final PayrollSummaryRow? payroll;
}

double attendanceDayValue(String status) => switch (status) {
      'geldi' => 1,
      'yarım gün' => 0.5,
      _ => 0,
    };

/// Kişi listesini üç kaynaktan birleştirir: aktif personel (employees.read
/// varsa), o ayın puantajı ve maaş özeti (payroll.read varsa). Pasif
/// personel yalnızca o ay verisi varsa listededir -- işten ayrılanın son
/// ayı kaybolmasın (maaş özetiyle aynı kural).
///
/// [employees] null = personel listesi okunamadı (izin yok/hata): o zaman
/// kimse "pasif" sayılmaz, çünkü bilinemez.
List<PersonMonth> peopleForMonth({
  required List<Employee>? employees,
  required List<AttendanceRecord> records,
  PayrollMonth? payroll,
  String? todayIso,
}) {
  final byId = <String, ({String name, String position, bool? active})>{};
  for (final e in employees ?? const <Employee>[]) {
    byId[e.id] = (name: e.fullName, position: e.position, active: e.isActive);
  }
  for (final p in payroll?.summary ?? const <PayrollSummaryRow>[]) {
    final known = byId[p.employeeId];
    byId[p.employeeId] = (
      name: known?.name ?? p.fullName,
      position: (known?.position.isNotEmpty ?? false) ? known!.position : p.position,
      active: known?.active ?? p.isActive,
    );
  }
  for (final r in records) {
    byId.putIfAbsent(
      r.employeeId,
      () => (
        name: r.employeeName.isEmpty ? r.employeeId : r.employeeName,
        position: '',
        // Aktif listesi okunduysa ve kişi orada yoksa pasiftir.
        active: employees == null ? null : false,
      ),
    );
  }

  final recordsBy = <String, List<AttendanceRecord>>{};
  for (final r in records) {
    recordsBy.putIfAbsent(r.employeeId, () => []).add(r);
  }
  final payrollBy = {for (final p in payroll?.summary ?? const <PayrollSummaryRow>[]) p.employeeId: p};

  final out = [
    for (final MapEntry(key: id, value: info) in byId.entries)
      () {
        final own = [...?recordsBy[id]]..sort((a, b) => b.date.compareTo(a.date));
        return PersonMonth(
          employeeId: id,
          fullName: info.name,
          position: info.position,
          isActive: info.active ?? true,
          workedDays: own.fold(0.0, (s, r) => s + attendanceDayValue(r.status)),
          workHours: own.fold(0.0, (s, r) => s + r.workHours),
          records: own,
          today: todayIso == null ? null : own.where((r) => r.date == todayIso).firstOrNull,
          payroll: payrollBy[id],
        );
      }(),
  ];
  // Aktifler önce, sonra ada göre (Türkçe büyük/küçük harf farkı gözetmeden).
  out.sort((a, b) {
    if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
    return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
  });
  return out;
}

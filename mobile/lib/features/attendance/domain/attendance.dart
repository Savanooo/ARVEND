class Employee {
  final String id;
  final String fullName;
  final String position;
  final bool isActive;

  const Employee({required this.id, required this.fullName, required this.position, required this.isActive});

  factory Employee.fromJson(Map<String, dynamic> json) => Employee(
        id: json['id'] as String,
        fullName: json['full_name'] as String,
        position: json['position'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? true,
      );
}

/// bkz. mobile/API_CONTRACT.md#attendance - GPS/geofence YOK, saf elle giriş.
class AttendanceRecord {
  final String id;
  final String employeeId;
  final String employeeName;
  final String date;
  final String checkIn;
  final String checkOut;
  final double workHours;
  final String status;
  final String note;

  const AttendanceRecord({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.date,
    required this.checkIn,
    required this.checkOut,
    required this.workHours,
    required this.status,
    required this.note,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) => AttendanceRecord(
        id: json['id'] as String,
        employeeId: json['employee_id'] as String,
        employeeName: json['employee_name'] as String? ?? '',
        date: json['date'] as String,
        checkIn: json['check_in'] as String? ?? '',
        checkOut: json['check_out'] as String? ?? '',
        workHours: (json['work_hours'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String,
        note: json['note'] as String? ?? '',
      );
}

const kAttendanceStatuses = ['geldi', 'yarım gün', 'gelmedi', 'izinli'];

/// İstemci tarafı filtre -- backend'in `ListAttendanceByMonth` sorgusunun
/// org+ay dışında filtre parametresi YOK (bkz. Phase 1 doğrulaması), bu
/// yüzden personel/durum filtresi zaten çekilmiş TEK aylık liste üzerinde
/// uygulanır; yeni bir ağ isteği İCAT EDİLMEZ.
bool attendanceMatchesFilters(
  AttendanceRecord record, {
  String? employeeFilter,
  String? statusFilter,
}) {
  if (employeeFilter != null && record.employeeId != employeeFilter) return false;
  if (statusFilter != null && record.status != statusFilter) return false;
  return true;
}

/// Verilen tarih için hiç kaydı olmayan aktif personeli döndürür -- "Bugün"
/// bölümündeki "kaydı girilmemiş" listesi için.
List<Employee> missingAttendanceFor(List<Employee> employees, List<AttendanceRecord> recordsForDate) {
  final presentIds = recordsForDate.map((r) => r.employeeId).toSet();
  return employees.where((e) => e.isActive && !presentIds.contains(e.id)).toList();
}

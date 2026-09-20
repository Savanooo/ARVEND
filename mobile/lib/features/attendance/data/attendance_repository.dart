import '../../../core/api/api_client.dart';
import '../domain/attendance.dart';

class AttendanceRepository {
  AttendanceRepository(this._client);
  final ApiClient _client;

  Future<List<Employee>> employees({String filter = ''}) async {
    final json = await _client.get<Map<String, dynamic>>('/employees', query: {
      if (filter.isNotEmpty) 'filter': filter,
    });
    return (json['employees'] as List).cast<Map<String, dynamic>>().map(Employee.fromJson).toList();
  }

  /// `month`: "YYYY-MM"; boşsa backend geçerli ayı kullanır.
  Future<List<AttendanceRecord>> list({String month = ''}) async {
    final json = await _client.get<Map<String, dynamic>>('/attendance', query: {
      if (month.isNotEmpty) 'month': month,
    });
    return (json['attendance'] as List).cast<Map<String, dynamic>>().map(AttendanceRecord.fromJson).toList();
  }

  Future<AttendanceRecord> create({
    required String employeeId,
    required String date,
    String checkIn = '',
    String checkOut = '',
    required double workHours,
    required String status,
    String note = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/attendance', data: {
      'employee_id': employeeId,
      'date': date,
      'check_in': checkIn,
      'check_out': checkOut,
      'work_hours': workHours,
      'status': status,
      'note': note,
    });
    return AttendanceRecord.fromJson(json);
  }

  /// Backend'de `employee_id`/`date` Update'te KABUL EDİLMEZ (servis
  /// katmanı bu iki alanı hiç okumaz -- bkz. backend Phase 1 doğrulaması:
  /// bir kayıt "hangi personel, hangi tarih" olduğu OLUŞTURULDUKTAN SONRA
  /// DEĞİŞTİRİLEMEZ) -- bu yüzden istek gövdesinde bu ikisi hiç YOK.
  Future<AttendanceRecord> update(
    String id, {
    String checkIn = '',
    String checkOut = '',
    required double workHours,
    required String status,
    String note = '',
  }) async {
    final json = await _client.put<Map<String, dynamic>>('/attendance/$id', data: {
      'check_in': checkIn,
      'check_out': checkOut,
      'work_hours': workHours,
      'status': status,
      'note': note,
    });
    return AttendanceRecord.fromJson(json);
  }
}

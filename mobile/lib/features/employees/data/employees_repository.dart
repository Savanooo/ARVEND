import '../../../core/api/api_client.dart';
import '../domain/employee_record.dart';

/// Personel -- okuma `employees.read`, ekleme/düzenleme/pasifleştirme
/// `employees.manage` (bkz. router.go /employees). Backend'de metin
/// araması ve sayfalama YOK; `filter` yalnızca aktif/pasif.
class EmployeesRepository {
  EmployeesRepository(this._client);
  final ApiClient _client;

  /// `filter`: '' (tümü) | 'aktif' | 'pasif'.
  Future<List<EmployeeRecord>> list({String filter = ''}) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/employees',
      query: {if (filter.isNotEmpty) 'filter': filter},
    );
    return (json['employees'] as List).cast<Map<String, dynamic>>().map(EmployeeRecord.fromJson).toList();
  }

  Future<EmployeeRecord> get(String id) async =>
      EmployeeRecord.fromJson(await _client.get<Map<String, dynamic>>('/employees/$id'));

  /// Backend yeni kaydı her zaman aktif açar.
  Future<EmployeeRecord> create(EmployeeInput input) async =>
      EmployeeRecord.fromJson(await _client.post<Map<String, dynamic>>('/employees', data: input.toJson()));

  Future<EmployeeRecord> update(String id, EmployeeInput input) async =>
      EmployeeRecord.fromJson(await _client.put<Map<String, dynamic>>('/employees/$id', data: input.toJson()));

  /// Hesap <-> personel eşleşme önerileri (employees.manage +
  /// organization.users.read). Yalnızca öneri -- bağlamak [update] ile.
  Future<List<EmployeeLinkSuggestion>> linkSuggestions() async {
    final json = await _client.get<Map<String, dynamic>>('/employees/link-suggestions');
    return (json['suggestions'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(EmployeeLinkSuggestion.fromJson)
        .toList();
  }

  /// DELETE = pasifleştirme (hard delete YOK -- mesai/görev geçmişi
  /// personele bağlı kalır).
  Future<void> archive(String id) => _client.delete<dynamic>('/employees/$id');
}
